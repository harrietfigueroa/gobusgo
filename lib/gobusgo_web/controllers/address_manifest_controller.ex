defmodule GobusgoWeb.AddressManifestController do
  @retry_after_seconds 60

  @moduledoc """
  Serves every county's manifest of the address shards from
  `Gobusgo.Addresses`.

  The manifests name the shard files by addresses that never change
  content, so they are the one thing a reader revalidates. The statuses,
  headers, and body are described in `priv/openapi.json`; while no county is
  built the answer asks the reader to retry after #{@retry_after_seconds}
  seconds.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.Addresses
  alias GobusgoWeb.Problem

  @doc "Answers the manifest, that the client holds it already, or that there is none."
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
