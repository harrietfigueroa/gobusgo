defmodule GobusgoWeb.FallbackController do
  @moduledoc """
  Answers a request under `/api` that no other route matches with `404`
  problem details, whatever media types the request accepts.
  """

  use Phoenix.Controller, formats: [:json]

  alias GobusgoWeb.Problem

  @doc "Answers `404` problem details that name the method and the path."
  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params) do
    Problem.respond(conn, %{
      status: 404,
      detail: "No route matches #{conn.method} #{conn.request_path}."
    })
  end
end
