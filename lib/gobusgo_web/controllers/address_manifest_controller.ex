defmodule GobusgoWeb.AddressManifestController do
  @retry_after_seconds 60

  @moduledoc """
  Serves every county's manifest of the address shards from
  `Gobusgo.Addresses`, as `{"counties": [...]}`.

  The manifests name the shard files by addresses that never change
  content, so they are the one thing a reader revalidates: it is answered with
  `cache-control: no-cache` and a strong `etag`, the SHA-256 of the body,
  and a request whose `if-none-match` names that tag gets `304` with no
  body. While no county is built it answers `503` problem details with
  `Retry-After: #{@retry_after_seconds}`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.Addresses
  alias GobusgoWeb.Problem

  @doc "Answers `200` with the manifest, `304` when the client holds it already, or `503` while there is none."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Addresses.manifest(Addresses) do
      {:ok, manifest} -> respond(conn, Gobusgo.CanonicalJson.encode(manifest))
      :none -> unavailable(conn)
    end
  end

  defp respond(conn, body) do
    etag = ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")
    conn = conn |> put_resp_header("cache-control", "no-cache") |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> Problem.respond(%{status: 503, detail: "No address build is available yet."})
  end
end
