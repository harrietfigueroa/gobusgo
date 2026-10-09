defmodule GobusgoWeb.PublicHost do
  @moduledoc """
  What the endpoint is started with for the host name its pages are served
  on. Everything here is pure.
  """

  @doc """
  The endpoint options for `host`, a host name `Gobusgo.Config` has
  validated: the host of the URLs the endpoint generates, and the one origin
  a socket is accepted from, a page of that host under any scheme and port.
  With no host the options are empty, and the endpoint keeps what it is
  configured with.
  """
  @spec endpoint_options(String.t() | nil) :: Keyword.t()
  def endpoint_options(nil), do: []

  # An origin written with no scheme admits every scheme and port of its host.
  # deps/phoenix/lib/phoenix/socket/transport.ex, parse_origin/1 — checked 2026-10-09
  def endpoint_options(host) when is_binary(host) do
    [url: [host: host], check_origin: ["//" <> host]]
  end
end
