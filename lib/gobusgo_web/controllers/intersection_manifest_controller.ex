defmodule GobusgoWeb.IntersectionManifestController do
  @retry_after_seconds 60

  @moduledoc """
  Serves the manifest of the published intersection files, which a build
  stores through `Gobusgo.Writer` under a name of its own per build. The
  controller reads the newest of them through `Gobusgo.Reader`
  (`Gobusgo.Intersections.Publication.manifest/1`) on every request, so it
  serves whichever backend the application stores through.

  The manifest names the files by hashes that never change content, so it is
  the one thing a reader revalidates: it is answered with
  `cache-control: no-cache` and a strong `etag`, the SHA-256 of the body, and
  a request whose `if-none-match` names that tag gets `304` with no body.
  While no build is stored, or the stored manifest cannot be read or is not
  the JSON object a build writes, it answers `503` problem details with
  `Retry-After: #{@retry_after_seconds}`.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Gobusgo.Intersections.Publication
  alias Gobusgo.Schema
  alias GobusgoWeb.Problem

  @manifest_schema {:map,
                    %{
                      "builtAt" => :string,
                      "index" => {:map, %{"path" => :string}},
                      "shards" => {:list, {:map, %{"path" => :string}}}
                    }}

  @doc "Answers `200` with the manifest, `304` when the client holds it already, or `503` while there is none."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case read() do
      {:ok, body} -> respond(conn, body)
      {:error, reason} -> unavailable(conn, reason)
    end
  end

  defp read do
    with {:ok, body} <- Publication.manifest([]),
         {:ok, decoded} <- decode(body),
         nil <- Schema.mismatch(decoded, @manifest_schema) do
      {:ok, body}
    else
      {:error, reason} -> {:error, reason}
      _mismatch -> {:error, :malformed_manifest}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed_manifest}
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

  defp unavailable(conn, :not_found), do: respond_unavailable(conn)

  defp unavailable(conn, reason) do
    Logger.error("Intersection manifest not readable", reason: inspect(reason))
    respond_unavailable(conn)
  end

  defp respond_unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> Problem.respond(%{status: 503, detail: "No intersection build is available yet."})
  end
end
