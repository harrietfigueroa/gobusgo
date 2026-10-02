defmodule Gobusgo.ConfigTest do
  # Verifies settings validation as pure functions of the application
  # environment keyword list, so no global state is touched.
  use ExUnit.Case, async: true

  alias Gobusgo.Config

  describe "fetch_one_bus_away/1" do
    test "returns the settings when the URL and API key are present" do
      env = [base_url: "https://oba.example.test", api_key: "secret"]

      assert Config.fetch_one_bus_away(env) ==
               {:ok, %{base_url: "https://oba.example.test", api_key: "secret"}}
    end

    for key <- [:base_url, :api_key] do
      test "reports #{key} as missing when it is nil" do
        env =
          Keyword.put(
            [base_url: "https://oba.example.test", api_key: "secret"],
            unquote(key),
            nil
          )

        assert Config.fetch_one_bus_away(env) == {:error, {:missing, unquote(key)}}
      end

      test "reports #{key} as missing when it is blank" do
        env =
          Keyword.put(
            [base_url: "https://oba.example.test", api_key: "secret"],
            unquote(key),
            "  "
          )

        assert Config.fetch_one_bus_away(env) == {:error, {:missing, unquote(key)}}
      end
    end

    test "reports base_url as missing for an empty environment" do
      assert Config.fetch_one_bus_away([]) == {:error, {:missing, :base_url}}
    end
  end

  describe "fetch_http/1" do
    test "returns the loopback address and port 4000 for an empty environment" do
      assert Config.fetch_http([]) == {:ok, %{ip: {127, 0, 0, 1}, port: 4000}}
    end

    test "returns the defaults for blank values" do
      assert Config.fetch_http(host: " ", port: "") == {:ok, %{ip: {127, 0, 0, 1}, port: 4000}}
    end

    test "returns the configured IPv4 address and port" do
      assert Config.fetch_http(host: "0.0.0.0", port: "8080") ==
               {:ok, %{ip: {0, 0, 0, 0}, port: 8080}}
    end

    test "returns a configured IPv6 address" do
      assert Config.fetch_http(host: "::1", port: "4000") ==
               {:ok, %{ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 4000}}
    end

    for host <- ["localhost", "256.0.0.1", "127.0.0.1:4000"] do
      test "reports host as invalid for #{host}" do
        assert Config.fetch_http(host: unquote(host)) == {:error, {:invalid, :host}}
      end
    end

    for port <- ["0", "65536", "-1", "80a", "4000.0", "http"] do
      test "reports port as invalid for #{port}" do
        assert Config.fetch_http(port: unquote(port)) == {:error, {:invalid, :port}}
      end
    end
  end
end
