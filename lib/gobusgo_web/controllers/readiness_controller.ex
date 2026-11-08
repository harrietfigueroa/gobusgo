defmodule GobusgoWeb.ReadinessController do
  @retry_after_seconds 5

  @moduledoc """
  Answers whether the views hold what a start fills them with, as
  `Gobusgo.OneBusAway.Readiness` reads it. It reads the views and starts no
  fetch.

  While the views are filling it answers `503` problem details with
  `Retry-After: #{@retry_after_seconds}` and a `detail` that names the gap.

  Both answers also hold the freshness of the current route and stop tile
  archive, as `GobusgoWeb.RouteStopTiles.freshness/1` judges it: `tiles` is
  `"current"`, `"stale"`, or `"none"`, and `tilesAgeSeconds` the archive's
  age where its name holds its build time. An archive whose name holds none
  is `"stale"` with no age. The archive never changes the status or the
  code, so a failing tile build leaves the instance ready.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.OneBusAway.Readiness
  alias GobusgoWeb.ErrorJSON
  alias GobusgoWeb.RouteStopTiles

  @doc ~s(Answers 200 with `{"status": "ready"}` once the views are full, and 503 before that.)
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    destination = RouteStopTiles.current_destination(RouteStopTiles)
    freshness = RouteStopTiles.freshness(%{destination: destination, now: DateTime.utc_now()})
    tiles = tiles(freshness)

    case Readiness.read([]) do
      :ready ->
        json(conn, Map.merge(%{"status" => "ready"}, tiles))

      {:filling, gap} ->
        problem = ErrorJSON.problem(%{status: 503, detail: detail(gap)})

        conn
        |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
        |> put_status(503)
        |> json(Map.merge(problem, tiles))
    end
  end

  defp tiles(:none), do: %{"tiles" => "none"}
  defp tiles(:unrecognized), do: %{"tiles" => "stale"}

  defp tiles({:current, age_seconds}),
    do: %{"tiles" => "current", "tilesAgeSeconds" => age_seconds}

  defp tiles({:stale, age_seconds}), do: %{"tiles" => "stale", "tilesAgeSeconds" => age_seconds}

  defp detail(:agency_fetch_absent), do: "No agency fetch is available yet."

  defp detail({:route_items_unattempted, 1}), do: "1 route item has not been fetched yet."

  defp detail({:route_items_unattempted, count}) when count > 1 do
    "#{count} route items have not been fetched yet."
  end
end
