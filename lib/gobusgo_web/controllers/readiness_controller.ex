defmodule GobusgoWeb.ReadinessController do
  @retry_after_seconds 5

  @moduledoc """
  Answers whether the views hold what a start fills them with, as
  `Gobusgo.OneBusAway.Readiness` reads it. It reads the views and starts no
  fetch.

  While the views are filling it answers `503` problem details with
  `Retry-After: #{@retry_after_seconds}` and a `detail` that names the gap.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.OneBusAway.Readiness
  alias GobusgoWeb.Problem

  @doc ~s(Answers 200 with `{"status": "ready"}` once the views are full, and 503 before that.)
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Readiness.read([]) do
      :ready ->
        json(conn, %{"status" => "ready"})

      {:filling, gap} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
        |> Problem.respond(%{status: 503, detail: detail(gap)})
    end
  end

  defp detail(:agency_fetch_absent), do: "No agency fetch is available yet."

  defp detail({:route_items_unattempted, 1}), do: "1 route item has not been fetched yet."

  defp detail({:route_items_unattempted, count}) when count > 1 do
    "#{count} route items have not been fetched yet."
  end
end
