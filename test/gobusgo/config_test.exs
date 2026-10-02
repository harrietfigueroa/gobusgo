defmodule Gobusgo.ConfigTest do
  # Verifies OneBusAway settings validation as a pure function of the
  # application environment keyword list, so no global state is touched.
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
end
