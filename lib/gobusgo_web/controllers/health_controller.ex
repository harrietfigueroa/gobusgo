defmodule GobusgoWeb.HealthController do
  @moduledoc """
  Answers whether the server is running. It checks nothing beyond the
  server itself, so a 200 says the endpoint accepts requests.
  """

  use Phoenix.Controller, formats: [:json]

  @doc """
  Answers 200 with `{"status": "ok"}`, and `revision`, the commit the
  application was built from, beside it when the build names one.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    {:ok, revision} = Gobusgo.Config.revision()
    json(conn, body(revision))
  end

  defp body(nil), do: %{"status" => "ok"}
  defp body(revision) when is_binary(revision), do: %{"status" => "ok", "revision" => revision}
end
