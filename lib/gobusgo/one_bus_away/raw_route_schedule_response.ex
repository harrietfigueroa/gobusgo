defmodule Gobusgo.OneBusAway.RawRouteScheduleResponse do
  @destination_prefix "raw/oba/schedule-for-route"
  @route_segment_prefix "route="
  @service_date_segment_prefix "service-date="
  @escape "."

  @moduledoc """
  The stored form of one successful `schedule-for-route` response: its
  logical destination and its content. Everything here is pure, so the stored
  form is a function of the response and the request identifier alone. The
  parts every dataset shares are those of `Gobusgo.OneBusAway.RawResponse`.

  ## Destination

      #{@destination_prefix}/dt=YYYY-MM-DD/#{@route_segment_prefix}<route>/#{@service_date_segment_prefix}YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json.gz

  `dt` is the date of the fetch and `service-date` the service date the
  request asked for, so the responses of one service date are found by
  their names. `route` is the route identifier with every byte outside
  `A-Z`, `a-z`, `0-9`, `_`, and `-` written as `#{@escape}` and its two
  uppercase hexadecimal digits, so each identifier has one name and every
  name is a valid destination segment.

  ## Content

  The wrapper of `Gobusgo.OneBusAway.RawResponse`, whose `meta` also holds
  `routeId` and `serviceDate`, the route and the service date the request
  asked for, the date as `YYYY-MM-DD`. A response without service on the
  date is not stored.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.RequestId

  @type t :: RawResponse.t()

  @typedoc "One stored fetch of a route's schedule, as `parse/1` returns it."
  @type parsed :: %{
          route_id: String.t(),
          service_date: Date.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          schedule: RouteSchedules.schedule()
        }

  @typedoc """
    * `:invalid_json` — the content is not JSON.
    * `:schema_mismatch` — the content is not the wrapper `build/1` produces,
      its `meta` names no route or service date, or its data is not that
      route's schedule.
    * `:hash_mismatch` — the data does not hash to `meta.dataSha256`.
    * `:destination_mismatch` — `meta` names a destination other than the one
      the content was read from.
  """
  @type parse_error :: RawResponse.parse_error()

  @doc "The prefix every destination of this dataset starts with."
  @spec destination_prefix() :: String.t()
  def destination_prefix, do: @destination_prefix

  @doc """
  Returns the destination and content that store `response`, a response
  that holds a schedule, under `request_id`, with the fetch time and data
  hash they carry. Raises `Gobusgo.Assert.AssertionError` for a response
  without service, an empty route identifier, and everything
  `Gobusgo.OneBusAway.RawResponse.build/1` raises for.
  """
  @spec build(%{response: RouteSchedules.response(), request_id: RequestId.t()}) :: t()
  def build(%{response: response, request_id: request_id}) do
    %{route_id: route_id, service_date: service_date, schedule: schedule} = response
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(is_struct(service_date, Date), "service date must be a Date")
    Assert.condition(is_map(schedule), "only a response that holds a schedule is stored")

    RawResponse.build(%{
      response: response,
      request_id: request_id,
      prefix: @destination_prefix,
      segments: segments_of(route_id, service_date),
      meta: %{"routeId" => route_id, "serviceDate" => Date.to_iso8601(service_date)}
    })
  end

  @doc """
  Returns the fetch that `content`, read back from `destination`, stored. The
  first rule the content breaks returns as a value.
  """
  @spec parse(%{destination: String.t(), content: binary()}) ::
          {:ok, parsed()} | {:error, parse_error()}
  def parse(%{destination: destination, content: content})
      when is_binary(destination) and is_binary(content) do
    raw =
      RawResponse.parse(%{
        destination: destination,
        content: content,
        prefix: @destination_prefix,
        segments: &segments/1
      })

    with {:ok, %{data: data, meta: %{"routeId" => route_id} = meta} = stored} <- raw,
         {:ok, service_date} <- Date.from_iso8601(meta["serviceDate"]),
         {:ok, schedule} <- parse_schedule(data, route_id) do
      {:ok,
       %{
         route_id: route_id,
         service_date: service_date,
         destination: destination,
         fetched_at: stored.fetched_at,
         data_sha256: stored.data_sha256,
         request_id: stored.request_id,
         schedule: schedule
       }}
    else
      {:error, :invalid_format} -> {:error, :schema_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp segments(meta) do
    with %{"routeId" => route_id, "serviceDate" => text} when is_binary(route_id) <- meta,
         true <- route_id != "",
         true <- is_binary(text),
         {:ok, service_date} <- Date.from_iso8601(text) do
      {:ok, segments_of(route_id, service_date)}
    else
      _other -> :error
    end
  end

  defp segments_of(route_id, service_date) do
    [route_segment(route_id), @service_date_segment_prefix <> Date.to_iso8601(service_date)]
  end

  defp parse_schedule(data, route_id) do
    case RouteSchedules.parse(data, route_id) do
      {:ok, schedule} -> {:ok, schedule}
      {:error, _reason} -> {:error, :schema_mismatch}
    end
  end

  defp route_segment(route_id) do
    @route_segment_prefix <> for(<<byte <- route_id>>, into: "", do: escape(byte))
  end

  defp escape(byte) when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"_-" do
    <<byte>>
  end

  defp escape(byte), do: @escape <> Base.encode16(<<byte>>)
end
