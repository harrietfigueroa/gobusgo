defmodule GobusgoWeb.Mcp.Tools.Arrivals do
  @ms_per_second 1_000
  @seconds_per_minute 60

  @moduledoc """
  The `arrivals` tool: a stop's next arrivals as the vehicle page shows
  them, from the stop's fetch in the arrivals view.

  A call for a stop holds it through `GobusgoWeb.Mcp.StopHolds`, which has
  the arrival source fetch it as a page's open stop does, so the tool is
  read-only for every other dataset. `data.status` says what the call
  found:

    * `arrivals` — the stop has a fetch, and `data.arrivals` holds the
      arrivals, soonest first, with the fetch in `meta`.
    * `fetching` — the stop is held and has no fetch yet; ask again after
      `data.retryAfterSeconds`, one request of the arrival source.
    * `capacity_reached` — MCP clients hold as many stops as they may, the
      stop has no vehicle page open and the call did not hold it; ask again
      after `data.retryAfterSeconds`, the length of a hold.
    * `unknown_stop` — the stop view holds no such stop.

  A held answer is keyed on the arrival fetch, the vehicle fetches that move
  a prediction, and the minute, since an arrival that has passed leaves the
  answer.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.AnswerCache
  alias GobusgoWeb.Mcp.StopHolds
  alias GobusgoWeb.StopArrivals
  alias GobusgoWeb.TransitQuery

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "arrivals",
      "title" => "Next arrivals at a stop",
      "description" =>
        Answer.description(
          "Lists the next arrivals at a stop, soonest first, at most " <>
            "#{StopArrivals.arrival_count_max()}, each predicted or scheduled. Find the stop " <>
            "identifier with the find tool. A stop nobody has asked about recently has no " <>
            "arrivals yet: the answer is status fetching with the seconds to wait before " <>
            "asking again."
        ),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "stopId" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "A stop identifier."
          }
        },
        "required" => ["stopId"],
        "additionalProperties" => false
      },
      "outputSchema" => Answer.output_schema(data_schema())
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema, do: {:map, %{"stopId" => :string}}

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"stopId" => ""}), do: {:error, "The stop identifier is empty."}

  def call(%{"stopId" => stop_id}) do
    case TransitQuery.stop_known?(stop_id) do
      false -> respond(%{"status" => "unknown_stop", "stopId" => stop_id})
      true -> hold_and_answer(stop_id)
    end
  end

  defp hold_and_answer(stop_id) do
    case StopHolds.hold(stop_id, %{hold_ms: StopHolds.hold_ms()}) do
      :held ->
        answer(stop_id)

      # A stop a vehicle page has open is fetched whether or not the call
      # holds it, so the cap has nothing to refuse.
      :cap_reached ->
        case StopHolds.demanded?(stop_id) do
          true ->
            answer(stop_id)

          false ->
            wait(%{status: "capacity_reached", stop_id: stop_id, wait_ms: StopHolds.hold_ms()})
        end

      :unavailable ->
        {:error, "The demand registry is not answering. Ask again in a few seconds."}
    end
  end

  defp answer(stop_id) do
    now_minute = Integer.floor_div(System.system_time(:second), @seconds_per_minute)
    key = {:arrivals, stop_id, TransitQuery.arrivals_version(stop_id), now_minute}

    case AnswerCache.fetch(key, fn -> shape(TransitQuery.stop_answer(stop_id)) end) do
      {:arrivals, answer} ->
        Answer.result(answer)

      :fetching ->
        wait(%{
          status: "fetching",
          stop_id: stop_id,
          wait_ms: Sources.arrival_interval_ms()
        })
    end
  end

  defp shape(%{shown: %{status: :waiting}}), do: :fetching

  defp shape(%{shown: %{stop_id: stop_id, arrivals: arrivals}, fetch: fetch}) do
    kept = Enum.take(arrivals, Answer.item_count_max())

    {:arrivals,
     %{
       "data" => %{
         "status" => "arrivals",
         "stopId" => stop_id,
         "arrivals" => Enum.map(kept, &arrival/1)
       },
       "meta" => Answer.meta(%{fetch: fetch, count: length(kept), extra: %{}})
     }}
  end

  defp arrival(line) do
    %{
      "route" => line.route,
      "color" => line.color,
      "headsign" => line.headsign,
      "minutes" => line.minutes,
      "time" => time(line.time_ms),
      "predicted" => line.predicted,
      "tripId" => line.trip_id,
      "scheduledTime" => time(line.scheduled_ms)
    }
  end

  defp time(unix_ms) do
    unix_ms |> DateTime.from_unix!(:millisecond) |> Answer.iso()
  end

  defp wait(%{status: status, stop_id: stop_id, wait_ms: wait_ms}) do
    # The wait rounds up to whole seconds, so asking after it never asks early.
    retry_after_seconds = Integer.floor_div(wait_ms + @ms_per_second - 1, @ms_per_second)

    respond(%{
      "status" => status,
      "stopId" => stop_id,
      "retryAfterSeconds" => retry_after_seconds
    })
  end

  defp respond(data) do
    Answer.result(%{"data" => data, "meta" => Answer.meta(%{fetch: nil, count: 0, extra: %{}})})
  end

  defp data_schema do
    nullable_string = %{"type" => ["string", "null"]}
    string = %{"type" => "string"}

    %{
      "type" => "object",
      "properties" => %{
        "status" => %{"enum" => ["arrivals", "fetching", "capacity_reached", "unknown_stop"]},
        "stopId" => string,
        "retryAfterSeconds" => %{"type" => "integer"},
        "arrivals" => %{
          "type" => "array",
          "maxItems" => Answer.item_count_max(),
          "items" => %{
            "type" => "object",
            "properties" => %{
              "route" => nullable_string,
              "color" => nullable_string,
              "headsign" => nullable_string,
              "minutes" => %{"type" => "integer"},
              "time" => %{"type" => "string", "format" => "date-time"},
              "predicted" => %{"type" => "boolean"},
              "tripId" => nullable_string,
              "scheduledTime" => %{"type" => "string", "format" => "date-time"}
            },
            "required" => ["minutes", "time", "predicted", "scheduledTime"]
          }
        }
      },
      "required" => ["status", "stopId"]
    }
  end
end
