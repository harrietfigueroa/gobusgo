defmodule GobusgoWeb.Endpoint do
  @moduledoc """
  The HTTP endpoint: the plugs every request passes through before the
  router. `Gobusgo.Application` starts it with the listener address.

  A response with an error status leaves as `application/problem+json`. A
  request for `/health` is not logged.
  """

  use Phoenix.Endpoint, otp_app: :gobusgo

  @json_content_type "application/json"
  # https://www.rfc-editor.org/rfc/rfc9457#section-3 — checked 2026-10-02
  @problem_content_type "application/problem+json"
  @error_status_min 400
  @health_path "/health"

  # A plug that can raise goes in a router pipeline, never here. The router
  # hands the error renderer the connection that carries the callback
  # problem_content_type/2 registers; an error raised by a plug of this
  # module reaches the renderer with the connection as it arrived.
  # deps/phoenix/lib/phoenix/endpoint.ex, __before_compile__/1 — checked 2026-10-02
  plug :problem_content_type
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}
  plug GobusgoWeb.Router

  @doc "The level a request is logged at, or `false` for a request that is not logged."
  @spec log_level(Plug.Conn.t()) :: Logger.level() | false
  def log_level(%Plug.Conn{request_path: @health_path}), do: false
  def log_level(%Plug.Conn{}), do: :info

  defp problem_content_type(conn, _options) do
    Plug.Conn.register_before_send(conn, fn conn ->
      if conn.status >= @error_status_min do
        mark_problem(conn)
      else
        conn
      end
    end)
  end

  defp mark_problem(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [@json_content_type <> parameters] ->
        Plug.Conn.put_resp_header(conn, "content-type", @problem_content_type <> parameters)

      _other ->
        conn
    end
  end
end
