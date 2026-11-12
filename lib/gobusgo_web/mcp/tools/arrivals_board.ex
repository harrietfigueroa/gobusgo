defmodule GobusgoWeb.Mcp.Tools.ArrivalsBoard do
  @moduledoc """
  The `arrivals_board` tool: a stop's next arrivals on a board the arrivals
  board app (`GobusgoWeb.Mcp.Resources.ArrivalsBoard`) keeps current while
  the rider watches, or, with a `when`, the stop's scheduled departures from
  that time.

  The tool answers what the `arrivals` tool answers for the stop, holding
  the stop through `GobusgoWeb.Mcp.StopHolds` as that tool does, and adds
  `data.stopName` where the stop view holds the stop's name, so the app's
  first render needs no further call.

  `when` is the `when` of `plan_trip` and is checked by it, except that a mode
  of `arriveBy` is an error, since the board lists departures from a time.
  `route` lists the routes a list of departures keeps, and the board ignores
  it without a `when`. With a `when` the tool holds no stop and reads no
  arrivals: it answers `data.status` `scheduled` with the stop's name, or
  `unknown_stop`, and the app reads the time and routes from the call's
  arguments and lists the departures on the device from the routing
  snapshots, so the server reads no schedule.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.Resources.ArrivalsBoard
  alias GobusgoWeb.Mcp.Tools.Arrivals
  alias GobusgoWeb.Mcp.Tools.PlanTrip
  alias GobusgoWeb.TransitQuery

  @route_count_max 10
  @route_id_length_max 100

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "arrivals_board",
      "title" => "Arrivals board",
      "description" =>
        Answer.description(
          "Shows the next arrivals at a stop on a board that updates itself while the rider " <>
            "watches, and answers what the arrivals tool answers for the stop. Find the stop " <>
            "identifier with the find tool. Use it when the rider wants to watch a stop; " <>
            "use arrivals to read the arrivals once. With when, the board lists the " <>
            "scheduled departures from that time instead, a bounded list, and does not update: " <>
            "use it for what the arrivals tool cannot answer, such as the last bus tonight " <>
            "or the first bus tomorrow, with when.mode departAt, and route identifiers from " <>
            "the find tool to keep one route. A departure within the next 35 minutes carries " <>
            "a note that the live time comes from the arrivals tool. The departures reach the " <>
            "model as context where the host takes it."
        ),
      "inputSchema" => input_schema(),
      "outputSchema" => output_schema(),
      "_meta" => %{"ui" => %{"resourceUri" => ArrivalsBoard.uri()}}
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema do
    {:map, fields} = Arrivals.arguments_schema()

    {:map,
     Map.merge(fields, %{
       "when" => PlanTrip.when_arguments_schema(),
       "route" => {:optional, {:list, :string}}
     })}
  end

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"stopId" => stop_id} = arguments) do
    with :ok <- check_mode(Map.get(arguments, "when")),
         :ok <- PlanTrip.check_when(Map.get(arguments, "when")),
         :ok <- check_routes(Map.get(arguments, "route")) do
      answer(arguments, stop_id)
    end
  end

  # A board for a later time never polls, so its call neither reads arrivals
  # nor holds the stop, which would take one of the held stops for a minute.
  defp answer(%{"when" => _time}, "") do
    Arrivals.call(%{"stopId" => ""})
  end

  defp answer(%{"when" => _time}, stop_id) do
    case TransitQuery.stop_name(stop_id) do
      {:ok, name} ->
        scheduled(%{"status" => "scheduled", "stopId" => stop_id, "stopName" => name})

      :unknown ->
        case TransitQuery.stop_known?(stop_id) do
          true -> scheduled(%{"status" => "scheduled", "stopId" => stop_id})
          false -> scheduled(%{"status" => "unknown_stop", "stopId" => stop_id})
        end
    end
  end

  defp answer(_arguments, stop_id) do
    with {:ok, %{"structuredContent" => answer}} <- Arrivals.call(%{"stopId" => stop_id}) do
      named(answer, TransitQuery.stop_name(stop_id))
    end
  end

  defp scheduled(data) do
    Answer.result(%{"data" => data, "meta" => Answer.meta(%{fetch: nil, count: 0, extra: %{}})})
  end

  defp check_mode(%{"mode" => "arriveBy"}) do
    {:error,
     "when.mode arriveBy is not one the board takes: the board lists departures from a time. " <>
       "Ask again with when.mode departAt, or now."}
  end

  defp check_mode(_time), do: :ok

  defp check_routes(nil), do: :ok

  defp check_routes(routes) when length(routes) > @route_count_max do
    {:error, "route holds at most #{@route_count_max} route identifiers."}
  end

  defp check_routes(routes) do
    case Enum.all?(routes, &route_id?/1) do
      true -> :ok
      false -> {:error, "route identifiers are 1 to #{@route_id_length_max} characters."}
    end
  end

  defp route_id?(route_id), do: String.length(route_id) in 1..@route_id_length_max

  defp named(%{"data" => data, "meta" => meta}, {:ok, name}) do
    Answer.result(%{"data" => Map.put(data, "stopName", name), "meta" => meta})
  end

  defp named(answer, :unknown), do: Answer.result(answer)

  defp input_schema do
    route = %{
      "type" => "array",
      "maxItems" => @route_count_max,
      "items" => %{"type" => "string", "minLength" => 1, "maxLength" => @route_id_length_max},
      "description" =>
        "Route identifiers a list of departures keeps, from the find tool. Every route " <>
          "when absent. Used only with when."
    }

    update_in(Arrivals.definition()["inputSchema"], ["properties"], fn properties ->
      Map.merge(properties, %{"when" => PlanTrip.when_schema(), "route" => route})
    end)
  end

  defp output_schema do
    stop_name = %{"type" => "string"}
    schema = Arrivals.definition()["outputSchema"]

    update_in(schema, ["properties", "data", "properties"], fn properties ->
      properties
      |> Map.put("stopName", stop_name)
      |> update_in(["status", "enum"], &(&1 ++ ["scheduled"]))
    end)
  end
end
