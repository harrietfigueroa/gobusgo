defmodule Gobusgo.OneBusAway.AgencyBatch.Consumer do
  @moduledoc """
  Processes the stored response each "response stored" event names. This
  module decodes and hands over; the event lives in
  `Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent` and the processing in
  `Gobusgo.OneBusAway.AgencyBatch`.

  `consume/2` takes record values, the bytes `StoredEvent.record/1` builds,
  and processes them in order in the calling process. A value that is not a
  "response stored" event is skipped. A stored response that fails to
  process is left failed and the next value is taken: the processor has
  logged the failure, and a later fetch brings readers up to date.

  Each call logs at most once itself: `warning` with the count of skipped
  values.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.Publisher

  @doc """
  Processes the stored response of every event in `values`, at most
  `Gobusgo.Publisher.record_count_max/0` record values. `process_options`
  are the options of `Gobusgo.OneBusAway.AgencyBatch.process/2`.
  """
  @spec consume(Keyword.t(), [binary()]) :: :ok
  def consume(process_options, values) when is_list(process_options) and is_list(values) do
    count = length(values)

    Assert.condition(
      count <= Publisher.record_count_max(),
      "values must hold at most #{Publisher.record_count_max()} records, got: #{count}"
    )

    invalid_count =
      Enum.reduce(values, 0, fn value, invalid_count ->
        case StoredEvent.decode(value) do
          {:ok, %{destination: destination}} ->
            process(destination, process_options)
            invalid_count

          {:error, _reason} ->
            invalid_count + 1
        end
      end)

    if invalid_count >= 1 do
      Logger.warning("Agency batch consumer skipped invalid events", invalid_count: invalid_count)
    end

    :ok
  end

  defp process(destination, process_options) do
    case AgencyBatch.process(destination, process_options) do
      {:ok, _result} -> :ok
      {:error, %{class: class}} when class in [:permanent, :transient] -> :ok
    end
  end
end
