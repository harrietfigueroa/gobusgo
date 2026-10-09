defmodule GobusgoWeb.PublicHostTest do
  # Verifies what the endpoint is started with for a public host name, and
  # that those options make the socket's origin check admit pages of that
  # host and no other. The check is Phoenix's own, called with a request that
  # carries an origin header; no socket is opened.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias GobusgoWeb.PublicHost
  alias Phoenix.Socket.Transport

  @host "d111111abcdef8.cloudfront.net"

  describe "endpoint_options/1" do
    test "names the host for the URLs the endpoint generates" do
      assert Keyword.fetch!(PublicHost.endpoint_options(@host), :url) == [host: @host]
    end

    test "leaves the endpoint as it is configured when there is no host" do
      assert PublicHost.endpoint_options(nil) == []
    end
  end

  describe "the origin check under endpoint_options/1" do
    for origin <- ["https://#{@host}", "http://#{@host}", "http://#{@host}:4000"] do
      test "admits a page at #{origin}" do
        assert checked(unquote(origin), @host).halted == false
      end
    end

    for {reason, origin} <- [
          {"another host", "https://gobusgo.example"},
          {"a subdomain of the host", "https://www.#{@host}"},
          {"a host that ends with the host", "https://evil#{@host}"}
        ] do
      test "refuses a page of #{reason}" do
        {conn, _log} = with_log(fn -> checked(unquote(origin), @host) end)

        assert {conn.halted, conn.status} == {true, 403}
      end
    end
  end

  # The handler names the cache entry Phoenix keeps the parsed origins under,
  # so each call takes one of its own.
  defp checked(origin, host) do
    handler = Module.concat(__MODULE__, "Handler#{System.unique_integer([:positive])}")

    :get
    |> conn("/live/websocket")
    |> put_req_header("origin", origin)
    |> Transport.check_origin(handler, GobusgoWeb.Endpoint, PublicHost.endpoint_options(host))
  end
end
