defmodule GobusgoWeb.RouteLines do
  @default_color "#6b7280"

  @moduledoc """
  The lines of the routes in the route and stop tile archive: one line per
  route that an agency lists and that has a path, from the fetches of the
  two route views. Everything here is pure.

  A line holds the route's `id`, its `color` as a CSS color, its names, and
  its `polylines`, the lines of the whole route in the encoded polyline
  format, which the browser decodes. A route whose source supplies no color
  is drawn in `#{@default_color}`. A route with a path that holds no
  polyline is a line with none, which draws nothing.

  The names are the route's `short_name` and `long_name` and its
  `agency_name`, the name of the agency the route's own record names, each
  `nil` where there is none. They are text from outside the application,
  which a map shows as data.

  An archive tells what it was built from by a version per route:
  everything of the line but its polylines, with the fetch time of its path
  in their place, in microseconds since the Unix epoch. `versions/1` reads
  no path, so comparing versions holds and copies no polyline.
  """

  alias Gobusgo.Assert

  @type line :: %{
          id: String.t(),
          color: String.t(),
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          agency_name: String.t() | nil,
          polylines: [String.t()]
        }

  @typedoc """
  What an archive's build keeps of a line: the route's color as the source
  supplies it, six hexadecimal digits or `nil`, its names, and its path's
  fetch time in microseconds since the Unix epoch.
  """
  @type version :: %{
          color: String.t() | nil,
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          agency_name: String.t() | nil,
          path_fetch_microseconds: integer()
        }

  @type versions :: %{String.t() => version()}

  @doc "The color of a route whose source supplies none."
  @spec default_color() :: String.t()
  def default_color, do: @default_color

  @doc """
  Returns the version of every route to draw: each route of
  `route_fetches`, the current fetches of the route view, that has a fetch
  time in `path_fetch_times`, the fetch times of the route path view.
  `agency_names` holds the name of each agency by its identifier; a route
  whose agency it does not hold has no agency name.
  """
  @spec versions(%{
          route_fetches: [map()],
          path_fetch_times: %{String.t() => DateTime.t()},
          agency_names: %{String.t() => String.t()}
        }) :: versions()
  def versions(%{
        route_fetches: route_fetches,
        path_fetch_times: path_fetch_times,
        agency_names: agency_names
      })
      when is_list(route_fetches) and is_map(path_fetch_times) and is_map(agency_names) do
    for %{route_ids: route_ids, routes: routes} <- route_fetches,
        route_id <- route_ids,
        is_map_key(path_fetch_times, route_id),
        into: %{} do
      route = Map.fetch!(routes, route_id)
      fetched_at = Map.fetch!(path_fetch_times, route_id)

      {route_id,
       %{
         color: route["color"],
         short_name: route["shortName"],
         long_name: route["longName"],
         agency_name: Map.get(agency_names, route["agencyId"]),
         path_fetch_microseconds: DateTime.to_unix(fetched_at, :microsecond)
       }}
    end
  end

  @doc """
  Returns the line of the route whose path is `path_fetch`, a current fetch
  of the route path view, with the color and the names of `version`, the
  route's version.
  """
  @spec line(%{version: version(), path_fetch: map()}) :: line()
  def line(%{version: version, path_fetch: %{id: route_id, polylines: polylines}})
      when is_binary(route_id) and is_list(polylines) do
    %{
      id: route_id,
      color: css_color(version.color),
      short_name: version.short_name,
      long_name: version.long_name,
      agency_name: version.agency_name,
      polylines: Enum.map(polylines, & &1["points"])
    }
  end

  defp css_color(nil), do: @default_color

  defp css_color(color) when is_binary(color) do
    Assert.condition(byte_size(color) == 6, "a route color is six hexadecimal digits")
    "#" <> color
  end
end
