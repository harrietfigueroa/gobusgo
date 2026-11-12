defmodule GobusgoWeb.Mcp.Tools.ArrivalsBoard do
  @moduledoc """
  The `arrivals_board` tool: a stop's next arrivals on a board the arrivals
  board app (`GobusgoWeb.Mcp.Resources.ArrivalsBoard`) keeps current while
  the rider watches.

  The tool answers what the `arrivals` tool answers for the stop, holding
  the stop through `GobusgoWeb.Mcp.StopHolds` as that tool does, and adds
  `data.stopName` where the stop view holds the stop's name, so the app's
  first render needs no further call.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.Resources.ArrivalsBoard
  alias GobusgoWeb.Mcp.Tools.Arrivals
  alias GobusgoWeb.TransitQuery

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
            "use arrivals to read the arrivals once."
        ),
      "inputSchema" => Arrivals.definition()["inputSchema"],
      "outputSchema" => output_schema(),
      "_meta" => %{"ui" => %{"resourceUri" => ArrivalsBoard.uri()}}
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema, do: Arrivals.arguments_schema()

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"stopId" => stop_id} = arguments) do
    with {:ok, %{"structuredContent" => answer}} <- Arrivals.call(arguments) do
      named(answer, TransitQuery.stop_name(stop_id))
    end
  end

  defp named(%{"data" => data, "meta" => meta}, {:ok, name}) do
    Answer.result(%{"data" => Map.put(data, "stopName", name), "meta" => meta})
  end

  defp named(answer, :unknown), do: Answer.result(answer)

  defp output_schema do
    stop_name = %{"type" => "string"}
    schema = Arrivals.definition()["outputSchema"]

    update_in(schema, ["properties", "data", "properties"], &Map.put(&1, "stopName", stop_name))
  end
end
