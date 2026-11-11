defmodule GobusgoWeb.OpenApiController do
  @moduledoc """
  Serves `priv/openapi.json`, the public OpenAPI document, byte for byte.

  The file is read when this module compiles and `@external_resource` makes
  a change to it recompile the module, so a request reads no file and the
  release needs the file at build time only. The tag is the quoted lowercase
  hexadecimal SHA-256 of the body, computed at the same time. The statuses,
  headers, and body are described in `priv/openapi.json`.
  """

  use Phoenix.Controller, formats: [:json]

  @document_path Path.expand("../../../priv/openapi.json", __DIR__)
  @external_resource @document_path
  @document File.read!(@document_path)
  @etag ~s(") <> Base.encode16(:crypto.hash(:sha256, @document), case: :lower) <> ~s(")

  @doc "Answers the document, or that the client holds it already."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn = conn |> put_resp_header("cache-control", "no-cache") |> put_resp_header("etag", @etag)

    if @etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      conn |> put_resp_content_type("application/json") |> send_resp(200, @document)
    end
  end
end
