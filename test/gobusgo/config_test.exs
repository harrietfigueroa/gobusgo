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

  describe "fetch_shared_vehicles/1" do
    test "takes an interval of 60 seconds when none is configured" do
      assert Config.fetch_shared_vehicles([]) == {:ok, %{interval_ms: 60_000}}
    end

    for interval_ms <- [60_000, 120_000, 3_600_000] do
      test "returns the configured interval of #{interval_ms} ms" do
        assert Config.fetch_shared_vehicles(interval_ms: unquote(interval_ms)) ==
                 {:ok, %{interval_ms: unquote(interval_ms)}}
      end
    end

    for interval_ms <- [59_999, 3_600_001, 0, 60_000.0, "60000", nil] do
      test "reports the interval #{inspect(interval_ms)} as invalid" do
        assert Config.fetch_shared_vehicles(interval_ms: unquote(interval_ms)) ==
                 {:error, {:invalid, :shared_vehicles_interval_ms}}
      end
    end
  end

  describe "fetch_vehicle_motion/1" do
    @default_motion %{
      zoom_min: 14.0,
      zoom_max: 16.0,
      hysteresis: 0.25,
      vehicle_count_max: 100,
      rates: [%{zoom: 14.0, rate_hz: 4}, %{zoom: 15.0, rate_hz: 8}]
    }

    test "takes the defaults when nothing is configured" do
      assert Config.fetch_vehicle_motion([]) == {:ok, @default_motion}
    end

    test "takes the defaults for blank values" do
      env = [zoom_min: " ", zoom_max: "", hysteresis: nil, vehicle_count_max: "", rates: ""]
      assert Config.fetch_vehicle_motion(env) == {:ok, @default_motion}
    end

    test "returns a configured band of 13 to 17" do
      env = [
        zoom_min: "13",
        zoom_max: "17.5",
        hysteresis: "0.5",
        vehicle_count_max: "60",
        rates: "13:2, 14.5:6,16:12"
      ]

      assert Config.fetch_vehicle_motion(env) ==
               {:ok,
                %{
                  zoom_min: 13.0,
                  zoom_max: 17.5,
                  hysteresis: 0.5,
                  vehicle_count_max: 60,
                  rates: [
                    %{zoom: 13.0, rate_hz: 2},
                    %{zoom: 14.5, rate_hz: 6},
                    %{zoom: 16.0, rate_hz: 12}
                  ]
                }}
    end

    test "keeps the default rates inside a narrowed band that holds them" do
      assert {:ok, %{zoom_min: 14.0, zoom_max: 15.5}} =
               Config.fetch_vehicle_motion(zoom_max: "15.5")
    end

    invalid = [
      {"a minimum zoom that is not a number", [zoom_min: "fourteen"], :vehicle_motion_zoom_min},
      {"a negative minimum zoom", [zoom_min: "-1", rates: "0:4"], :vehicle_motion_zoom_min},
      {"a maximum zoom past 24", [zoom_max: "25"], :vehicle_motion_zoom_max},
      {"a maximum zoom at the minimum", [zoom_max: "14"], :vehicle_motion_zoom_max},
      {"a maximum zoom below the minimum", [zoom_max: "13"], :vehicle_motion_zoom_max},
      {"a negative hysteresis", [hysteresis: "-0.1"], :vehicle_motion_hysteresis},
      {"a hysteresis of half the band", [hysteresis: "1"], :vehicle_motion_hysteresis},
      {"a hysteresis that is not a number", [hysteresis: "a bit"], :vehicle_motion_hysteresis},
      {"a cap of zero vehicles", [vehicle_count_max: "0"], :vehicle_motion_vehicle_count_max},
      {"a cap above the canvas's 100", [vehicle_count_max: "101"],
       :vehicle_motion_vehicle_count_max},
      {"a fractional cap", [vehicle_count_max: "50.5"], :vehicle_motion_vehicle_count_max},
      {"a rate of zero", [rates: "14:0"], :vehicle_motion_rates},
      {"a rate above 60 Hz", [rates: "14:61"], :vehicle_motion_rates},
      {"a fractional rate", [rates: "14:4.5"], :vehicle_motion_rates},
      {"a rate's zoom below the band", [rates: "13:4"], :vehicle_motion_rates},
      {"a rate's zoom at the maximum", [rates: "14:4,16:8"], :vehicle_motion_rates},
      {"rates out of order", [rates: "15:8,14:4"], :vehicle_motion_rates},
      {"two rates at one zoom", [rates: "14:4,14:8"], :vehicle_motion_rates},
      {"a rate with no zoom", [rates: "4"], :vehicle_motion_rates},
      {"more than eight rates",
       [zoom_max: "24", rates: "14:1,15:2,16:3,17:4,18:5,19:6,20:7,21:8,22:9"],
       :vehicle_motion_rates},
      {"default rates outside a moved band", [zoom_min: "10", zoom_max: "12"],
       :vehicle_motion_rates}
    ]

    for {name, env, key} <- invalid do
      test "reports #{name} as invalid" do
        assert Config.fetch_vehicle_motion(unquote(env)) == {:error, {:invalid, unquote(key)}}
      end
    end

    # The canvas over the map asserts it draws at most this many vehicles at
    # most this often, so the settings the page is handed stay inside them.
    test "caps the vehicles and the rate at the canvas's bounds" do
      source = File.read!("assets/js/vehicle_overlay_layout.js")
      [_match, count] = Regex.run(~r/export const VEHICLE_COUNT_MAX = (\d+)/, source)
      [_match, rate] = Regex.run(~r/export const RATE_HZ_MAX = (\d+)/, source)

      assert Config.vehicle_motion_vehicle_count_max_max() == String.to_integer(count)
      assert Config.vehicle_motion_rate_hz_max() == String.to_integer(rate)
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

  describe "fetch_places/1" do
    test "returns the configured directory" do
      assert Config.fetch_places(dir: "/data/places") == {:ok, %{dir: "/data/places"}}
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil directory", [dir: nil]},
          {"a blank directory", [dir: "  "]}
        ] do
      test "reports dir as missing for #{description}" do
        assert Config.fetch_places(unquote(env)) == {:error, {:missing, :dir}}
      end
    end
  end

  describe "fetch_intersections/1" do
    test "returns the configured directory" do
      assert Config.fetch_intersections(dir: "/data/intersections") ==
               {:ok, %{dir: "/data/intersections"}}
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil directory", [dir: nil]},
          {"a blank directory", [dir: "  "]}
        ] do
      test "reports dir as missing for #{description}" do
        assert Config.fetch_intersections(unquote(env)) == {:error, {:missing, :dir}}
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

  describe "fetch_file_origin/1" do
    # The origin the vehicle page fetches its published files from: an
    # address of a scheme and a host, and a port where one is named, with
    # nothing after them, so a path the page appends lands on that origin.
    @file_origin "https://ddxsy8xnmcfe8.cloudfront.net"

    for value <- [@file_origin, "http://localhost:4001"] do
      test "returns the configured origin #{value}" do
        assert Config.fetch_file_origin(origin: unquote(value)) == {:ok, unquote(value)}
      end
    end

    for {description, env} <- [
          {"an empty environment", []},
          {"a nil origin", [origin: nil]},
          {"a blank origin", [origin: "  "]}
        ] do
      test "returns nil for #{description}" do
        assert Config.fetch_file_origin(unquote(env)) == {:ok, nil}
      end
    end

    for {description, value} <- [
          {"an origin with no scheme", "ddxsy8xnmcfe8.cloudfront.net"},
          {"an ftp origin", "ftp://ddxsy8xnmcfe8.cloudfront.net"},
          {"an origin with no host", "https://"},
          {"an origin with a trailing slash", "https://ddxsy8xnmcfe8.cloudfront.net/"},
          {"an origin with a path", "https://ddxsy8xnmcfe8.cloudfront.net/files"},
          {"an origin with a query", "https://ddxsy8xnmcfe8.cloudfront.net?x=1"},
          {"an origin with a fragment", "https://ddxsy8xnmcfe8.cloudfront.net#x"},
          {"an origin with a user", "https://user@ddxsy8xnmcfe8.cloudfront.net"},
          {"an origin with a space in it", "https://ddxsy8xnmcfe8 .cloudfront.net"}
        ] do
      test "reports the origin as invalid for #{description}" do
        assert Config.fetch_file_origin(origin: unquote(value)) ==
                 {:error, {:invalid, :file_origin}}
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
