defmodule Gobusgo.OneBusAway.ArrivalBatch do
  @moduledoc """
  Processes one stored response of the arrivals at a stop: the response at
  a destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as one record that holds every arrival. This module
  orchestrates and logs; the stored form of the input lives in
  `Gobusgo.OneBusAway.RawArrivalResponse` and the published form in
  `Gobusgo.OneBusAway.ArrivalBatch.Records`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same record again.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the `:stop_id`,
  the `:request_id` and `:fetched_at` of the fetch, and the `:arrival_count`
  of its arrivals.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_arrivals`. Nothing is
  published for a failure at `:read` or `:parse`.

  A call that publishes logs once at `debug`: every fetch of an open stop
  publishes. A failure returns to the caller and is not logged
  here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.ArrivalBatch.Records
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          stop_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          arrival_count: non_neg_integer()
        }

  @doc "Publishes the arrivals of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, parsed} <- parse(destination, content),
           :ok <- publish([Records.build(parsed)], Keyword.fetch!(options, :publish_options)) do
        {:ok,
         %{
           destination: destination,
           stop_id: parsed.stop_id,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           arrival_count: length(parsed.arrivals)
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Arrival batch published",
        destination: destination,
        request_id: published.request_id,
        arrival_count: published.arrival_count
      )
    end

    result
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
