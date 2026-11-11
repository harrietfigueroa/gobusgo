defmodule GobusgoWeb.Mcp.Tools.Route do
  @moduledoc """
  The `route` tool: a route's agency, names, and directions, each direction
  with its destination name and its stops in the order the route serves
  them, from the route view and the route path view
  (`GobusgoWeb.TransitQuery.route/1`). The tool starts no fetch.

  `data.status` says what the call found:

    * `route` — the route is listed, and `data.directions` holds its
      directions in the order its path holds them, each with at most
      `GobusgoWeb.Mcp.Answer.item_count_max/0` stops and `stopCount` of
      them in all. `meta.restCount` counts the stops the bound left out of
      every direction together, and `meta.fetchedAt` and `meta.requestId`
      name the route path fetch.
    * `unknown_route` — no agency's route fetch lists the route.

  A held answer is keyed on the route fetches, the route path fetch, and the
  stop fetches.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.AnswerCache
  alias GobusgoWeb.TransitQuery

  @unavailable "No route data is available yet. Ask again in a few seconds."

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "route",
      "title" => "Directions and stops of a route",
      "description" =>
        Answer.description(
          "Lists the directions of a route, each with its destination name and its stops in " <>
            "the order the route serves them, at most #{Answer.item_count_max()} stops in a " <>
            "direction, each with its identifier, name, code, and the direction it faces. " <>
            "Find the route identifier with the find tool, and ask the arrivals tool about a " <>
            "stop by the identifier given here."
        ),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "routeId" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "A route identifier."
          }
        },
        "required" => ["routeId"],
        "additionalProperties" => false
      },
      "outputSchema" => Answer.output_schema(data_schema())
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema, do: {:map, %{"routeId" => :string}}

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"routeId" => ""}), do: {:error, "The route identifier is empty."}

  def call(%{"routeId" => route_id}) do
    key = {:route, route_id, TransitQuery.route_version(route_id)}

    case AnswerCache.fetch(key, fn ->
           shape(%{route_id: route_id, found: TransitQuery.route(route_id)})
         end) do
      :unavailable -> {:error, @unavailable}
      {:ok, answer} -> Answer.result(answer)
    end
  end

  defp shape(%{found: :unavailable}), do: :unavailable

  defp shape(%{route_id: route_id, found: :unknown}) do
    {:ok,
     %{
       "data" => %{"status" => "unknown_route", "routeId" => route_id},
       "meta" => Answer.meta(%{fetch: nil, count: 0, extra: %{}})
     }}
  end

  defp shape(%{
         route_id: route_id,
         found: {:ok, %{route: route, directions: directions, fetch: fetch}}
       }) do
    kept = Enum.map(directions, &direction/1)
    kept_count = kept |> Enum.map(&length(&1["stops"])) |> Enum.sum()
    total_count = directions |> Enum.map(&length(&1.stops)) |> Enum.sum()

    {:ok,
     %{
       "data" => %{
         "status" => "route",
         "routeId" => route_id,
         "agencyId" => route["agencyId"],
         "shortName" => route["shortName"],
         "longName" => route["longName"],
         "directions" => kept
       },
       "meta" =>
         Answer.meta(%{
           fetch: fetch,
           count: kept_count,
           extra: %{"restCount" => total_count - kept_count}
         })
     }}
  end

  defp direction(%{id: id, name: name, stops: stops}) do
    kept = Enum.take(stops, Answer.item_count_max())

    %{
      "id" => id,
      "name" => name,
      "stopCount" => length(stops),
      "stops" => Enum.map(kept, &stop/1)
    }
  end

  defp stop(stop) do
    %{"id" => stop.id, "name" => stop.name, "code" => stop.code, "direction" => stop.direction}
  end

  defp data_schema do
    nullable_string = %{"type" => ["string", "null"]}

    %{
      "type" => "object",
      "properties" => %{
        "status" => %{"enum" => ["route", "unknown_route"]},
        "routeId" => %{"type" => "string"},
        "agencyId" => %{"type" => "string"},
        "shortName" => nullable_string,
        "longName" => nullable_string,
        "directions" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "name" => nullable_string,
              "stopCount" => %{"type" => "integer"},
              "stops" => %{
                "type" => "array",
                "maxItems" => Answer.item_count_max(),
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "name" => %{"type" => "string"},
                    "code" => nullable_string,
                    "direction" => nullable_string
                  },
                  "required" => ["id", "name"]
                }
              }
            },
            "required" => ["id", "stopCount", "stops"]
          }
        }
      },
      "required" => ["status", "routeId"]
    }
  end
end
