defmodule GobusgoWeb.Mcp.Tools.Vehicles do
  @moduledoc """
  The `vehicles` tool: the vehicles the vehicle page shows under the same
  `agency` and `route` filter, with the texts the page shows for each. The
  filter is the contract of `Gobusgo.OneBusAway.VehicleFilter`: agencies
  combine with routes as AND, and the values of one field as OR. The tool
  starts no fetch.

  `meta.fetchedAt` and `meta.requestId` name the oldest of the agency
  fetches the vehicles come from, so every vehicle is at least that fresh,
  and `meta.fetches` names each of them.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.VehicleFilter
  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.AnswerCache
  alias GobusgoWeb.TransitQuery

  @unavailable "No vehicle data is available yet. Ask again in a few seconds."

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "vehicles",
      "title" => "Vehicles on the map",
      "description" =>
        Answer.description(
          "Lists the transit vehicles the map shows, in agency order, at most " <>
            "#{Answer.item_count_max()}, optionally only those of the given agencies and " <>
            "routes. Find identifiers with the find tool. A vehicle's lateness and next " <>
            "stop are texts as the map shows them."
        ),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "agency" => id_list("Agency identifiers; a vehicle of any of them is kept."),
          "route" => id_list("Route identifiers; a vehicle on any of them is kept.")
        },
        "additionalProperties" => false
      },
      "outputSchema" => Answer.output_schema(data_schema())
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema do
    {:map, %{"agency" => {:optional, {:list, :string}}, "route" => {:optional, {:list, :string}}}}
  end

  @impl GobusgoWeb.Mcp.Tool
  def call(arguments) do
    raw = Map.take(arguments, Map.keys(VehicleFilter.spec()))

    case VehicleFilter.normalize(raw) do
      {:ok, filter} -> answer(filter)
      {:error, violations} -> {:error, refusal(violations)}
    end
  end

  defp answer(filter) do
    outcome =
      AnswerCache.fetch({:vehicles, filter, TransitQuery.vehicle_version()}, fn ->
        shape(TransitQuery.vehicles(filter))
      end)

    case outcome do
      :unavailable -> {:error, @unavailable}
      {:ok, answer} -> Answer.result(answer)
    end
  end

  defp shape(:unavailable), do: :unavailable

  defp shape({:ok, %{fetches: fetches, markers: markers}}) do
    kept = Enum.take(markers, Answer.item_count_max())

    # Every vehicle is at least as fresh as the oldest fetch it may come from.
    oldest =
      case fetches do
        [] -> nil
        fetches -> Enum.min_by(fetches, & &1.fetched_at, DateTime)
      end

    extra = %{
      "restCount" => length(markers) - length(kept),
      "fetches" => Enum.map(fetches, &fetch/1)
    }

    {:ok,
     %{
       "data" => %{"vehicles" => Enum.map(kept, &vehicle/1)},
       "meta" => Answer.meta(%{fetch: oldest, count: length(kept), extra: extra})
     }}
  end

  defp fetch(%{agency_id: agency_id, fetched_at: fetched_at, request_id: request_id}) do
    %{
      "agencyId" => agency_id,
      "fetchedAt" => Answer.iso(fetched_at),
      "requestId" => request_id
    }
  end

  defp vehicle({agency_id, marker}) do
    %{
      "id" => marker.id,
      "agencyId" => agency_id,
      "vehicleId" => marker.vehicle_id,
      "lat" => marker.lat,
      "lon" => marker.lon,
      "heading" => marker.heading,
      "routeId" => marker.route_id,
      "route" => marker.route,
      "headsign" => marker.headsign,
      "schedule" => marker.schedule,
      "nextStop" => marker.next_stop,
      "status" => Atom.to_string(marker.status),
      "locationAge" => marker.location_age,
      "realTime" => marker.real_time,
      "tripId" => marker.trip_id,
      "serviceDateMs" => marker.service_date_ms
    }
  end

  # A violation names the field and the reason and never the value.
  defp refusal(violations) do
    reasons =
      Enum.map_join(violations, "; ", fn %{field: field, reason: reason} ->
        "#{field || "filter"}: #{reason}"
      end)

    "The filter is not valid (" <>
      reasons <>
      "). At most " <>
      "#{Filter.value_count_max()} values of #{Filter.value_bytes_max()} bytes each."
  end

  defp id_list(description) do
    %{
      "type" => "array",
      "items" => %{"type" => "string", "maxLength" => Filter.value_bytes_max()},
      "maxItems" => Filter.value_count_max(),
      "description" => description
    }
  end

  defp data_schema do
    nullable_string = %{"type" => ["string", "null"]}
    string = %{"type" => "string"}

    %{
      "type" => "object",
      "properties" => %{
        "vehicles" => %{
          "type" => "array",
          "maxItems" => Answer.item_count_max(),
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => string,
              "agencyId" => string,
              "vehicleId" => string,
              "lat" => %{"type" => "number"},
              "lon" => %{"type" => "number"},
              "heading" => %{"type" => ["integer", "null"]},
              "routeId" => nullable_string,
              "route" => nullable_string,
              "headsign" => nullable_string,
              "schedule" => nullable_string,
              "nextStop" => nullable_string,
              "status" => %{"enum" => ["reported", "stale", "scheduled", "unknown"]},
              "locationAge" => string,
              "realTime" => string,
              "tripId" => nullable_string,
              "serviceDateMs" => %{"type" => ["integer", "null"]}
            },
            "required" => ["id", "agencyId", "vehicleId", "lat", "lon", "status"]
          }
        }
      },
      "required" => ["vehicles"]
    }
  end
end
