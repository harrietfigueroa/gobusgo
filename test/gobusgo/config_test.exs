defmodule Gobusgo.ConfigTest do
  # Verifies settings validation as pure functions of the application
  # environment keyword list, so no global state is touched.
  use ExUnit.Case, async: true

  alias Gobusgo.Config

  describe "fetch_one_bus_away/1" do
    test "returns the settings when the URL and API key are present" do
      env = [base_url: "https://oba.example.test", api_key: "secret"]

      assert Config.fetch_one_bus_away(env) ==
               {:ok, %Config.OneBusAway{base_url: "https://oba.example.test", api_key: "secret"}}
    end

    test "leaves the API key out of the inspected settings" do
      env = [base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"]
      {:ok, settings} = Config.fetch_one_bus_away(env)

      inspected = inspect(settings, limit: :infinity)
      refute inspected =~ "test-key-3f9a1c07be52"
      assert inspected =~ "https://oba.example.test"
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

  describe "fetch_storage/1" do
    @storage [
      bucket: "gobusgo-data",
      prefix: "production/",
      region: "us-west-2",
      endpoint: nil,
      credentials_relative_uri: "/v2/credentials/id",
      credentials_full_uri: nil,
      credentials_authorization: nil
    ]

    for bucket <- [nil, "", "  "] do
      test "is local for the bucket #{inspect(bucket)}" do
        assert Config.fetch_storage(Keyword.put(@storage, :bucket, unquote(bucket))) ==
                 {:ok, :local}
      end
    end

    test "is local for an empty environment" do
      assert Config.fetch_storage([]) == {:ok, :local}
    end

    test "returns the bucket with its regional address and the credentials address" do
      assert Config.fetch_storage(@storage) ==
               {:ok,
                %{
                  bucket: "gobusgo-data",
                  prefix: "production/",
                  region: "us-west-2",
                  endpoint: "https://gobusgo-data.s3.us-west-2.amazonaws.com",
                  credentials: %{
                    url: "http://169.254.170.2/v2/credentials/id",
                    authorization: nil
                  }
                }}
    end

    test "takes an empty key prefix for a prefix that is not set" do
      assert {:ok, %{prefix: ""}} = Config.fetch_storage(Keyword.put(@storage, :prefix, nil))
    end

    test "takes the endpoint that is set" do
      endpoint = "https://gobusgo-data.s3.dualstack.us-west-2.amazonaws.com"

      assert {:ok, %{endpoint: ^endpoint}} =
               Config.fetch_storage(Keyword.put(@storage, :endpoint, endpoint))
    end

    test "takes the full credentials address and its authorization" do
      env =
        Keyword.merge(@storage,
          credentials_relative_uri: nil,
          credentials_full_uri: "http://localhost:8080/credentials",
          credentials_authorization: "Basic abcd"
        )

      assert {:ok,
              %{
                credentials: %{
                  url: "http://localhost:8080/credentials",
                  authorization: "Basic abcd"
                }
              }} = Config.fetch_storage(env)
    end

    test "takes the relative credentials address over the full one" do
      env = Keyword.put(@storage, :credentials_full_uri, "http://localhost/credentials")

      assert {:ok, %{credentials: %{url: "http://169.254.170.2/v2/credentials/id"}}} =
               Config.fetch_storage(env)
    end

    for {key, value, error} <- [
          {:bucket, "Upper_Case", {:invalid, :bucket}},
          {:bucket, "ab", {:invalid, :bucket}},
          {:region, nil, {:missing, :region}},
          {:region, "us west", {:invalid, :region}},
          {:prefix, "production", {:invalid, :prefix}},
          {:prefix, "/production/", {:invalid, :prefix}},
          {:endpoint, "http://plain.example.com", {:invalid, :endpoint}},
          {:endpoint, "https://host.example.com/path", {:invalid, :endpoint}},
          {:credentials_relative_uri, nil, {:missing, :credentials_uri}},
          {:credentials_relative_uri, "v2/credentials", {:invalid, :credentials_uri}}
        ] do
      test "reports #{inspect(error)} for #{key} #{inspect(value)}" do
        env = Keyword.put(@storage, unquote(key), unquote(value))

        assert Config.fetch_storage(env) == {:error, unquote(error)}
      end
    end

    test "reports the credentials address as not valid for a full one that is no HTTP address" do
      env =
        Keyword.merge(@storage,
          credentials_relative_uri: nil,
          credentials_full_uri: "ftp://localhost/credentials"
        )

      assert Config.fetch_storage(env) == {:error, {:invalid, :credentials_uri}}
    end
  end

  describe "fetch_usage/1" do
    for recorded <- [true, false] do
      test "returns recorded as #{recorded} when it is configured so" do
        assert Config.fetch_usage(recorded: unquote(recorded)) ==
                 {:ok, %{recorded: unquote(recorded)}}
      end
    end

    test "reports recorded as invalid for an empty environment" do
      assert Config.fetch_usage([]) == {:error, {:invalid, :recorded}}
    end

    for value <- ["true", 1, nil] do
      test "reports recorded as invalid for #{inspect(value)}" do
        assert Config.fetch_usage(recorded: unquote(value)) == {:error, {:invalid, :recorded}}
      end
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

  describe "fetch_basemap/1" do
    test "returns the configured directory" do
      assert Config.fetch_basemap(dir: "/data/basemap") == {:ok, %{dir: "/data/basemap"}}
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil directory", [dir: nil]},
          {"a blank directory", [dir: "  "]}
        ] do
      test "reports dir as missing for #{description}" do
        assert Config.fetch_basemap(unquote(env)) == {:error, {:missing, :dir}}
      end
    end
  end

  describe "fetch_revision/1" do
    @revision "43402796c905c22db533043dee878950c74d5791"

    test "returns the configured commit" do
      assert Config.fetch_revision(revision: @revision) == {:ok, @revision}
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil commit", [revision: nil]},
          {"a blank commit", [revision: "  "]}
        ] do
      test "returns nil for #{description}" do
        assert Config.fetch_revision(unquote(env)) == {:ok, nil}
      end
    end

    for {description, value} <- [
          {"an abbreviated commit", "4340279"},
          {"an uppercase commit", String.upcase("43402796c905c22db533043dee878950c74d5791")},
          {"a commit with a space after it", "43402796c905c22db533043dee878950c74d5791 "},
          {"a commit of 41 digits", "43402796c905c22db533043dee878950c74d57910"},
          {"a branch name", "main"}
        ] do
      test "reports the commit as invalid for #{description}" do
        assert Config.fetch_revision(revision: unquote(value)) == {:error, {:invalid, :revision}}
      end
    end
  end

  describe "fetch_donation_url/1" do
    @donation_url "https://ko-fi.com/harrietwaters"

    test "returns the configured address" do
      assert Config.fetch_donation_url(url: @donation_url) == {:ok, @donation_url}
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil address", [url: nil]},
          {"a blank address", [url: "  "]}
        ] do
      test "returns nil for #{description}" do
        assert Config.fetch_donation_url(unquote(env)) == {:ok, nil}
      end
    end

    for {description, value} <- [
          {"an http address", "http://ko-fi.com/harrietwaters"},
          {"an address with no scheme", "ko-fi.com/harrietwaters"},
          {"an address with no host", "https:///harrietwaters"},
          {"a javascript address", "javascript:alert(1)"},
          {"an address with a space in it", "https://ko-fi.com/harriet waters"},
          {"an address with a space before it", " https://ko-fi.com/harrietwaters"}
        ] do
      test "reports the address as invalid for #{description}" do
        assert Config.fetch_donation_url(url: unquote(value)) ==
                 {:error, {:invalid, :donation_url}}
      end
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

  describe "fetch_public_host/1" do
    for host <- ["localhost", "d111111abcdef8.cloudfront.net", "gobusgo.example", "a-b.example"] do
      test "returns the configured host name #{host}" do
        assert Config.fetch_public_host(host: unquote(host), required: true) ==
                 {:ok, unquote(host)}
      end
    end

    test "returns nil for an unset host name that is not required" do
      assert Config.fetch_public_host(host: nil, required: false) == {:ok, nil}
    end

    test "returns nil for a blank host name that is not required" do
      assert Config.fetch_public_host(host: "  ", required: false) == {:ok, nil}
    end

    test "reports the host name as missing when it is required and unset" do
      assert Config.fetch_public_host(host: nil, required: true) ==
               {:error, {:missing, :public_host}}
    end

    for {reason, host} <- [
          {"a scheme", "https://gobusgo.example"},
          {"a port", "gobusgo.example:443"},
          {"a path", "gobusgo.example/vehicles"},
          {"an uppercase letter", "Gobusgo.example"},
          {"a space", "gobusgo .example"},
          {"an empty label", "gobusgo..example"},
          {"a label that starts with a hyphen", "-gobusgo.example"},
          {"more than 253 bytes", String.duplicate("a.", 127)}
        ] do
      test "reports a host name with #{reason} as invalid" do
        assert Config.fetch_public_host(host: unquote(host), required: false) ==
                 {:error, {:invalid, :public_host}}
      end
    end
  end
end
