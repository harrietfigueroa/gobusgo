defmodule GobusgoWeb.RouteStopTiles.Features do
  @stop_zoom_min 14
  @point_count_min 2
  @text_separator ", "
  @route_id_separator ","

  @moduledoc """
  The GeoJSON features of the route and stop tile archive, one encoded
  feature per line, which tippecanoe reads. Everything here is pure.

  A route's feature is a multi-line of its polylines with `routeId`,
  `color`, `shortName`, `longName`, and `agencyName`. A stop's feature is a
  point with `stopId`, `name`, `code`, `direction`, `routes` and `agencies`,
  the names of its routes and of their agencies joined by
  `#{@text_separator}`, `routeChips`, each named route's name and CSS
  color, which a map draws as chips beside the stop, as a JSON list of
  pairs, and `routeIds`, the identifiers of its drawn routes with
  `#{@route_id_separator}` before, between, and after them, so that a map
  can test for one route with a substring. A vector tile's property holds no
  list, which is why each list is one text. A property a route or a stop
  does not have is left out.

  A stop's feature starts at zoom #{@stop_zoom_min}, the zoom a map first
  draws stops at.
  """

  alias Gobusgo.Polyline
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.StopMarkers

  @doc "The zoom a stop's feature starts at."
  @spec stop_zoom_min() :: pos_integer()
  def stop_zoom_min, do: @stop_zoom_min

  @doc """
  The encoded feature of `line`, or `:no_geometry` for a route none of
  whose polylines has #{@point_count_min} points, or the reason a polyline
  does not decode.
  """
  @spec route(RouteLines.line()) ::
          {:ok, String.t()} | :no_geometry | {:error, {:polyline, Polyline.error()}}
  def route(%{id: id, color: color, polylines: polylines} = line)
      when is_binary(id) and is_binary(color) and is_list(polylines) do
    case pieces(polylines) do
      {:ok, []} ->
        :no_geometry

      {:ok, pieces} ->
        properties =
          drop_absent(%{
            "routeId" => id,
            "color" => color,
            "shortName" => line.short_name,
            "longName" => line.long_name,
            "agencyName" => line.agency_name
          })

        {:ok,
         JSON.encode!(%{
           "type" => "Feature",
           "geometry" => %{"type" => "MultiLineString", "coordinates" => pieces},
           "properties" => properties
         })}

      {:error, reason} ->
        {:error, {:polyline, reason}}
    end
  end

  @doc """
  The encoded feature of `marker`, whose drawn routes are `route_ids`.
  """
  @spec stop(%{marker: StopMarkers.marker(), route_ids: [String.t(), ...]}) :: {:ok, String.t()}
  def stop(%{marker: %{id: id, lat: lat, lon: lon} = marker, route_ids: [_ | _] = route_ids})
      when is_binary(id) and is_number(lat) and is_number(lon) do
    properties =
      drop_absent(%{
        "stopId" => id,
        "name" => marker.name,
        "code" => marker.code,
        "direction" => marker.direction,
        "routes" => Enum.join(marker.routes, @text_separator),
        "agencies" => Enum.join(marker.agencies, @text_separator),
        "routeIds" => route_ids_text(route_ids),
        "routeChips" => route_chips_text(marker.route_chips)
      })

    {:ok,
     JSON.encode!(%{
       "type" => "Feature",
       "geometry" => %{"type" => "Point", "coordinates" => [lon, lat]},
       "properties" => properties,
       "tippecanoe" => %{"minzoom" => @stop_zoom_min}
     })}
  end

  # A pair is a list rather than an object so that each stop's text repeats
  # no key names; the archive holds one per stop.
  defp route_chips_text(route_chips) do
    pairs = for %{name: name, color: color} <- route_chips, do: [name, color]
    JSON.encode!(pairs)
  end

  defp route_ids_text(route_ids) do
    @route_id_separator <> Enum.join(route_ids, @route_id_separator) <> @route_id_separator
  end

  # The pieces of `polylines` with at least the minimum of points, each a
  # list of points, or the first reason a polyline does not decode.
  defp pieces(polylines) do
    Enum.reduce_while(polylines, {:ok, []}, fn points, {:ok, pieces} ->
      case Polyline.decode(points) do
        {:ok, decoded} when length(decoded) >= @point_count_min ->
          {:cont, {:ok, [decoded | pieces]}}

        {:ok, _decoded} ->
          {:cont, {:ok, pieces}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pieces} -> {:ok, Enum.reverse(pieces)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_absent(properties), do: Map.reject(properties, fn {_key, value} -> value == nil end)
end
