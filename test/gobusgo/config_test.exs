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

  describe "fetch_ingestion/1" do
    for scheduled <- [true, false] do
      test "returns scheduled as #{scheduled} when it is configured so" do
        assert Config.fetch_ingestion(scheduled: unquote(scheduled)) ==
                 {:ok, %{scheduled: unquote(scheduled)}}
      end
    end

    test "reports scheduled as invalid for an empty environment" do
      assert Config.fetch_ingestion([]) == {:error, {:invalid, :scheduled}}
    end

    for value <- ["true", 1, nil] do
      test "reports scheduled as invalid for #{inspect(value)}" do
        assert Config.fetch_ingestion(scheduled: unquote(value)) ==
                 {:error, {:invalid, :scheduled}}
      end
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

  describe "fetch_kafka/1" do
    test "returns the local broker for an empty environment" do
      assert Config.fetch_kafka([]) == {:ok, %{endpoints: [{"localhost", 9092}]}}
    end

    test "returns the default for a blank value" do
      assert Config.fetch_kafka(bootstrap_servers: " ") ==
               {:ok, %{endpoints: [{"localhost", 9092}]}}
    end

    test "returns every configured endpoint in order" do
      assert Config.fetch_kafka(bootstrap_servers: "kafka:19092, b-2.example.test:9094") ==
               {:ok, %{endpoints: [{"kafka", 19_092}, {"b-2.example.test", 9094}]}}
    end

    for text <- ["kafka", "kafka:", ":9092", "kafka:0", "kafka:65536", "kafka:9092,", "a:1:2"] do
      test "reports bootstrap_servers as invalid for #{text}" do
        assert Config.fetch_kafka(bootstrap_servers: unquote(text)) ==
                 {:error, {:invalid, :bootstrap_servers}}
      end
    end

    test "reports bootstrap_servers as invalid for more than 16 endpoints" do
      text = Enum.map_join(1..17, ",", &"kafka-#{&1}:9092")

      assert Config.fetch_kafka(bootstrap_servers: text) ==
               {:error, {:invalid, :bootstrap_servers}}
    end
  end

  describe "fetch_secret_key_base/1" do
    @secret String.duplicate("s", 64)

    test "returns a configured secret of 64 bytes" do
      assert Config.fetch_secret_key_base(secret_key_base: @secret, required: true) ==
               {:ok, @secret}
    end

    test "returns nil for an unset secret that is not required" do
      assert Config.fetch_secret_key_base(secret_key_base: nil, required: false) == {:ok, nil}
    end

    test "returns nil for a blank secret that is not required" do
      assert Config.fetch_secret_key_base(secret_key_base: "  ", required: false) == {:ok, nil}
    end

    test "reports the secret as missing when it is required and unset" do
      assert Config.fetch_secret_key_base(secret_key_base: nil, required: true) ==
               {:error, {:missing, :secret_key_base}}
    end

    for required <- [true, false] do
      test "reports a secret shorter than 64 bytes as invalid when required is #{required}" do
        env = [secret_key_base: String.duplicate("s", 63), required: unquote(required)]

        assert Config.fetch_secret_key_base(env) == {:error, {:invalid, :secret_key_base}}
      end
    end
  end
end
