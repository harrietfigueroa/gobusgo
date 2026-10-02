defmodule Gobusgo.OneBusAway.ClientTest do
  # Verifies host/1 as a pure function of the settings; the request path is
  # exercised through the requester tests.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Client

  describe "host/1" do
    for {name, base_url, expected} <- [
          {"a bare origin", "https://oba.example.test", "oba.example.test"},
          {"an origin with a port and a path", "https://oba.example.test:8443/base",
           "oba.example.test"},
          {"an origin with user information", "https://user:secret@oba.example.test",
           "oba.example.test"}
        ] do
      test "returns the host name alone for #{name}" do
        settings = %{base_url: unquote(base_url), api_key: "test-key"}

        assert Client.host(settings) == unquote(expected)
      end
    end

    test "raises for a base URL without a host" do
      assert_raise AssertionError, ~r/host/, fn ->
        Client.host(%{base_url: "not a url", api_key: "test-key"})
      end
    end

    test "keeps the base URL out of the raised message" do
      exception =
        assert_raise AssertionError, fn ->
          Client.host(%{base_url: "user:secret-3f9a", api_key: "test-key"})
        end

      refute exception.message =~ "secret-3f9a"
    end
  end
end
