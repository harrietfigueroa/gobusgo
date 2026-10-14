defmodule GobusgoWeb.EndpointTest do
  # Checks the options the endpoint declares for the LiveView socket. No test
  # opens a socket, so the compression a browser negotiates is read from the
  # declaration the transport is started with.
  use ExUnit.Case, async: true

  describe "the LiveView socket" do
    test "offers per-message compression over WebSocket" do
      [{"/live", Phoenix.LiveView.Socket, options}] = GobusgoWeb.Endpoint.__sockets__()

      assert Keyword.fetch!(options[:websocket], :compress) == true
    end
  end
end
