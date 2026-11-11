defmodule GobusgoWeb.PublicCors do
  @moduledoc """
  A plug that lets a page of any origin read a public file with `GET` or
  `HEAD`: it sets `access-control-allow-origin: *` on the response to either,
  and touches no other method.

  The files it covers hold no credential and no personal data, and the
  requests that read them send none, so the wildcard origin is the whole of
  the policy. A request that needs a preflight is not a simple one, and none
  of these routes answers one.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options) when options == [], do: options

  @impl Plug
  def call(%Plug.Conn{method: method} = conn, _options) when method in ["GET", "HEAD"] do
    put_resp_header(conn, "access-control-allow-origin", "*")
  end

  def call(%Plug.Conn{} = conn, _options), do: conn
end
