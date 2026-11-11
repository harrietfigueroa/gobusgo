defmodule GobusgoWeb.Mcp.Tools.Find do
  @moduledoc """
  The `find` tool: the agencies, routes, and stops that a text names, for a
  client that has a name and needs the identifier. Agencies and routes are
  what the vehicle page's filter bar suggests for the text under no filter,
  the stops are those of `GobusgoWeb.TransitQuery.find/1`. The tool starts
  no fetch.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.AnswerCache
  alias GobusgoWeb.RouteOptions
  alias GobusgoWeb.TransitQuery

  @unavailable "No agency data is available yet. Ask again in a few seconds."

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "find",
      "title" => "Find agencies, routes, and stops",
      "description" =>
        Answer.description(
          "Finds the transit agencies, routes, and stops whose name holds a text, " <>
            "to get the identifiers the other tools take. Routes are found by their " <>
            "short name alone where they have one; a stop is also found by its code."
        ),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "maxLength" => RouteOptions.query_length_max(),
            "description" => "Part of a name or a stop code, whatever its case."
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      },
      "outputSchema" => Answer.output_schema(data_schema())
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema, do: {:map, %{"query" => :string}}

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"query" => query}) do
    text = RouteOptions.query(query)

    outcome =
      AnswerCache.fetch({:find, text, TransitQuery.find_version()}, fn -> answer(text) end)

    case outcome do
      :unavailable -> {:error, @unavailable}
      {:ok, answer} -> Answer.result(answer)
    end
  end

  defp answer(text) do
    case TransitQuery.find(text) do
      :unavailable ->
        :unavailable

      {:ok, found} ->
        count = length(found.agencies) + length(found.routes) + length(found.stops)

        {:ok,
         %{
           "data" => %{
             "agencies" => Enum.map(found.agencies, &agency/1),
             "routes" => Enum.map(found.routes, &route/1),
             "stops" => Enum.map(found.stops, &stop/1)
           },
           "meta" =>
             Answer.meta(%{
               fetch: found.fetch,
               count: count,
               extra: %{
                 "restCount" => found.rest_count,
                 "stopRestCount" => found.stop_rest_count
               }
             })
         }}
    end
  end

  defp agency(%{id: id, name: name}), do: %{"id" => id, "name" => name}

  defp route(%{id: id, name: name, detail: detail, agency_name: agency_name}) do
    %{"id" => id, "name" => name, "detail" => detail, "agencyName" => agency_name}
  end

  defp stop(%{id: id, name: name, code: code, direction: direction, lat: lat, lon: lon}) do
    %{
      "id" => id,
      "name" => name,
      "code" => code,
      "direction" => direction,
      "lat" => lat,
      "lon" => lon
    }
  end

  defp data_schema do
    nullable_string = %{"type" => ["string", "null"]}

    %{
      "type" => "object",
      "properties" => %{
        "agencies" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"id" => %{"type" => "string"}, "name" => %{"type" => "string"}},
            "required" => ["id", "name"]
          }
        },
        "routes" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "name" => %{"type" => "string"},
              "detail" => nullable_string,
              "agencyName" => nullable_string
            },
            "required" => ["id", "name", "detail", "agencyName"]
          }
        },
        "stops" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "name" => %{"type" => "string"},
              "code" => nullable_string,
              "direction" => nullable_string,
              "lat" => %{"type" => "number"},
              "lon" => %{"type" => "number"}
            },
            "required" => ["id", "name", "code", "direction", "lat", "lon"]
          }
        }
      },
      "required" => ["agencies", "routes", "stops"]
    }
  end
end
