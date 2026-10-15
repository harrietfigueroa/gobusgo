defmodule Gobusgo.OneBusAway.ArrivalBatch do
  @moduledoc """
  Processes one stored response of the arrivals at a stop: the response at
  a destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as two records in one call: one that holds every
  arrival, then one that holds the situations the response references.
  This module orchestrates and logs; the stored form of the input lives in
  `Gobusgo.OneBusAway.RawArrivalResponse` and the published forms in
  `Gobusgo.OneBusAway.ArrivalBatch.Records` and
  `Gobusgo.OneBusAway.ArrivalBatch.SituationRecords`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same record again.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:stop_id`,
  the `:request_id` and `:fetched_at` of the fetch, the `:arrival_count`
  of its arrivals, the `:situation_count`, and the
  `:situation_rejected_count` of the situations
  `Gobusgo.OneBusAway.Situations` rejects.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_arrivals`. Nothing is
  published for a failure at `:read` or `:parse`. After a failure at
  `:publish_arrivals` either record may be published, as the publisher
  contract says of a failed call.

  A call that publishes logs once at `debug`: every fetch of an open stop
  publishes. It logs once more at `warning` as `Situations rejected` when it
  rejected a situation, which the source's contract does not account for.
  A failure returns to the caller and is not logged here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.ArrivalBatch.Records
  alias Gobusgo.OneBusAway.ArrivalBatch.SituationRecords
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          stop_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          arrival_count: non_neg_integer(),
          situation_count: non_neg_integer(),
          situation_rejected_count: non_neg_integer()
        }

  @doc "Publishes the arrivals of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, parsed} <- parse(destination, content),
           records = [Records.build(parsed), SituationRecords.build(parsed)],
           :ok <- publish(records, Keyword.fetch!(options, :publish_options)) do
        {:ok,
         %{
           destination: destination,
           stop_id: parsed.stop_id,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           arrival_count: length(parsed.arrivals),
           situation_count: length(parsed.situations),
           situation_rejected_count: parsed.situation_rejected_count
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Arrival batch published",
        destination: destination,
        request_id: published.request_id,
        arrival_count: published.arrival_count,
        situation_count: published.situation_count
      )

      log_rejected_situations(published)
    end

    result
  end

  defp log_rejected_situations(%{situation_rejected_count: 0}), do: :ok

  defp log_rejected_situations(published) do
    Logger.warning("Situations rejected",
      destination: published.destination,
      rejected_count: published.situation_rejected_count
    )
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, BatchFailure.read(reason)}
    end
  end

  defp parse(destination, content) do
    case RawArrivalResponse.parse(%{destination: destination, content: content}) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, BatchFailure.parse(reason)}
    end
  end

  defp publish(records, publish_options) do
    case Publisher.publish(records, publish_options) do
      :ok -> :ok
      {:error, reason} -> {:error, BatchFailure.publish(:publish_arrivals, reason)}
    end
  end
end
