defmodule GobusgoWeb.RoutingManifestController do
  @moduledoc """
  Serves the manifest of the routing snapshots, the body of
  `GobusgoWeb.TransitQuery.routing_manifest/0`.

  The manifest names the snapshot files by addresses that never change
  content, so it is the one thing a reader revalidates: it is answered with
  `cache-control: no-cache` and a strong `etag`, the SHA-256 of the body,
  and a request whose `if-none-match` names that tag gets `304` with no
  body.
  """

  use Phoenix.Controller, formats: [:json]

  alias GobusgoWeb.TransitQuery

  @doc "Answers `200` with the manifest, or `304` when the client holds it already."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    body = TransitQuery.routing_manifest()
    etag = ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")
    conn = conn |> put_resp_header("cache-control", "no-cache") |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end
end
