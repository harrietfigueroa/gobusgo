defmodule GobusgoWeb.Mcp.Origin do
  @moduledoc """
  The decision on a request's `Origin` header. Everything here is pure.

  A request with no `Origin` header comes from something other than a
  browser page, and is allowed. A request with one is allowed when the origin
  names the public host, under any scheme and port, which is what the
  LiveView socket admits (`GobusgoWeb.PublicHost`), and refused otherwise: an
  origin of another host, a malformed one, and a header sent more than once.
  With no public host configured, outside production, every origin is
  allowed, as the socket does.
  """

  @type decision :: :allowed | :refused

  # Servers must validate Origin against DNS rebinding and answer an invalid
  # one with 403.
  # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#security-warning — checked 2026-11-11
  # https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#security-endpoint — checked 2026-11-11
  @doc """
  Whether a request whose `Origin` headers are `values`, one string per
  header sent, may proceed on a server whose public host is `public_host`.
  """
  @spec decide([String.t()], String.t() | nil) :: decision()
  def decide([], _public_host), do: :allowed
  def decide(_values, nil), do: :allowed
  def decide([value], public_host) when is_binary(value), do: names_host(value, public_host)
  def decide([_first, _second | _rest], _public_host), do: :refused

  # A browser's origin is a scheme, a host, and an optional port, with no
  # user information, path, query, or fragment.
  # https://www.rfc-editor.org/rfc/rfc6454#section-7 — checked 2026-11-11
  defp names_host(value, public_host) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when scheme in ["http", "https"] and is_binary(host) and path in [nil, ""] ->
        host_decision(String.downcase(host), public_host)

      %URI{} ->
        :refused
    end
  end

  defp host_decision(host, host), do: :allowed
  defp host_decision(_host, _public_host), do: :refused
end
