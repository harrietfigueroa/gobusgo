defmodule GobusgoWeb.RoutingManifestController do
  @moduledoc """
  Serves the manifest of the routing snapshots from `Gobusgo.Routing.Snapshots`.

  The manifest names the snapshot files by addresses that never change
  content, so it is the one thing a reader revalidates. The statuses,
  headers, and body are described in `priv/openapi.json`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.Routing.Snapshots

  @doc "Answers the manifest, or that the client holds it already."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    body = Gobusgo.CanonicalJson.encode(Snapshots.manifest(Snapshots))
    etag = ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")
    conn = conn |> put_resp_header("cache-control", "no-cache") |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end
end
