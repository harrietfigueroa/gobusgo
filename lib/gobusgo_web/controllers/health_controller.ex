defmodule GobusgoWeb.HealthController do
  @moduledoc """
  Answers whether the server is running. It checks nothing beyond the
  server itself, so a 200 says the endpoint accepts requests.
  """

  use Phoenix.Controller, formats: [:json]

  @doc "Answers 200 with `{\"status\": \"ok\"}`."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: json(conn, %{"status" => "ok"})
end
