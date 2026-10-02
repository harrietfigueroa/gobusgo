defmodule Gobusgo.OneBusAway.AgencyBatch.Output do
  @schema_version 1

  @moduledoc """
  The published form of one agency batch: its logical destination and its
  content. Everything here is pure, so the published form is a function of
  the batch's inputs alone.

  ## Destination

      processed/oba/agencies/<batchId>_<firstFetchedAt>_<lastFetchedAt>_<processedAt>.json

    * `batchId` is the window, `Gobusgo.OneBusAway.AgencyBatch.Window.id/1`.
    * `firstFetchedAt` and `lastFetchedAt` are the fetch times of the first
      and the last valid input, in UTC basic ISO 8601.
    * `processedAt` is the processing time in the same format.

  Names sort by window, then within a window by first fetch time, last fetch
  time, and processing time, in that order.

  ## Content

  One JSON object, `{"agencies": ..., "meta": ...}`, encoded compactly with
  object keys sorted.

  `agencies` comes from the latest valid input, sorted by `id`. Each agency
  holds `id`, `name`, `url`, `timezone`, and `coverage` with `lat`, `lon`,
  `latSpan`, and `lonSpan`.

  `meta` holds:

    * `schemaVersion`: #{@schema_version}. It rises when a field is removed
      or renamed, or changes type or meaning; an added field leaves it as is.
    * `batchId`, `windowStart`, `windowEnd`: the window, the bounds in UTC
      extended ISO 8601.
    * `processedAt`: the processing time in the same format.
    * `triggerId`: the identifier of the trigger that started the run.
    * `inputFileCount`: the valid and the skipped inputs together.
    * `inputs`: every valid input in destination order, as `destination`,
      `fetchedAt`, `dataSha256`, and `duplicate`, which is true when an
      earlier input carries the same `dataSha256`.
    * `skipped`: every invalid input, as `destination` and `reason`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.AgencyBatch.Window
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.RequestId

  @type skipped :: %{destination: String.t(), reason: RawAgencyResponse.parse_error()}

  @type request :: %{
          window: Window.t(),
          inputs: [RawAgencyResponse.parsed(), ...],
          skipped: [skipped()],
          processed_at: DateTime.t(),
          trigger_id: RequestId.t()
        }

  @type t :: %{destination: String.t(), content: binary(), duplicate_count: non_neg_integer()}

  @destination_prefix "processed/oba/agencies/"
  @utc_time_zone "Etc/UTC"

  @doc "Returns the prefix shared by every output of the batch `batch_id`."
  @spec destination_prefix(String.t()) :: String.t()
  def destination_prefix(batch_id) when is_binary(batch_id) do
    @destination_prefix <> batch_id <> "_"
  end

  @doc """
  Returns the destination and content that publish a batch, with the count of
  duplicate inputs. `inputs` holds at least one valid input, in destination
  order; `processed_at` is a UTC time at a whole second; `trigger_id` is a
  UUID version 7. Raises `Gobusgo.Assert.AssertionError` when the request
  breaks that contract.
  """
  @spec build(request()) :: t()
  def build(%{window: window, inputs: inputs, skipped: skipped, trigger_id: trigger_id} = request)
      when is_list(inputs) and is_list(skipped) do
    %{processed_at: %DateTime{} = processed_at} = request
    Window.assert_valid(window)
    Assert.condition(inputs != [], "a batch output needs at least one valid input")
    assert_ordered(inputs)
    assert_processed_at(processed_at)
    Assert.condition(RequestId.valid?(trigger_id), "trigger identifier must be a UUID version 7")

    input_entries = input_entries(inputs)
    latest = List.last(inputs)

    meta = %{
      "schemaVersion" => @schema_version,
      "batchId" => Window.id(window),
      "windowStart" => DateTime.to_iso8601(window.start_at, :extended),
      "windowEnd" => DateTime.to_iso8601(window.end_at, :extended),
      "processedAt" => DateTime.to_iso8601(processed_at, :extended),
      "triggerId" => trigger_id,
      "inputFileCount" => length(inputs) + length(skipped),
      "inputs" => input_entries,
      "skipped" => Enum.map(skipped, &skipped_entry/1)
    }

    %{
      destination: destination(window, inputs, processed_at),
      content: CanonicalJson.encode(%{"agencies" => agencies(latest), "meta" => meta}),
      duplicate_count: Enum.count(input_entries, & &1["duplicate"])
    }
  end

  defp destination(window, inputs, processed_at) do
    name =
      [List.first(inputs).fetched_at, List.last(inputs).fetched_at, processed_at]
      |> Enum.map_join("_", &DateTime.to_iso8601(&1, :basic))

    destination = destination_prefix(Window.id(window)) <> name <> ".json"

    Assert.condition(
      match?({:ok, _segments}, Destination.validate(destination)),
      "built an invalid destination"
    )

    destination
  end

  defp input_entries(inputs) do
    {entries, _hashes_seen} =
      Enum.map_reduce(inputs, MapSet.new(), fn input, hashes_seen ->
        entry = %{
          "destination" => input.destination,
          "fetchedAt" => DateTime.to_iso8601(input.fetched_at, :extended),
          "dataSha256" => input.data_sha256,
          "duplicate" => MapSet.member?(hashes_seen, input.data_sha256)
        }

        {entry, MapSet.put(hashes_seen, input.data_sha256)}
      end)

    entries
  end

  defp skipped_entry(%{destination: destination, reason: reason}) when is_atom(reason) do
    %{"destination" => destination, "reason" => Atom.to_string(reason)}
  end

  defp agencies(%{agencies: agencies}) do
    agencies
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn %{coverage: coverage} = agency ->
      %{
        "id" => agency.id,
        "name" => agency.name,
        "url" => agency.url,
        "timezone" => agency.timezone,
        "coverage" => %{
          "lat" => coverage.lat,
          "lon" => coverage.lon,
          "latSpan" => coverage.lat_span,
          "lonSpan" => coverage.lon_span
        }
      }
    end)
  end

  defp assert_ordered(inputs) do
    destinations = Enum.map(inputs, & &1.destination)

    Assert.condition(
      destinations == Enum.sort(destinations),
      "inputs must be in destination order"
    )
  end

  defp assert_processed_at(%DateTime{
         time_zone: time_zone,
         microsecond: {microsecond, _precision}
       }) do
    Assert.condition(
      time_zone == @utc_time_zone,
      "processed_at must be in UTC, got: #{time_zone}"
    )

    Assert.condition(
      microsecond == 0,
      "processed_at must be at a whole second, got #{microsecond} microseconds"
    )
  end
end
