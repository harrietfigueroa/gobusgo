defmodule Gobusgo.OneBusAway.AgenciesTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files,
  # so every outcome (success, value errors, raised assertions) is observed
  # through the public fetch/2 contract with no network access.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Agencies

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name Agencies
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %Gobusgo.Config.OneBusAway{base_url: "https://oba.example.test", api_key: @api_key}
  @fast_options [
    plug: {Req.Test, @stub_name},
    gate: @gate,
    max_retries: 0,
    retry_delay_ms_base: 1
  ]

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp stub_body(body, status \\ 200) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp stub_fixture(name, status \\ 200), do: stub_body(fixture(name), status)

  defp fetch(options \\ []), do: Agencies.fetch(@settings, Keyword.merge(@fast_options, options))

  describe "fetch/2 success" do
    test "returns agencies with coverage resolved against references" do
      stub_fixture("agencies_with_coverage")

      assert {:ok, agencies} = fetch()

      assert agencies == [
               %{
                 id: "1",
                 name: "Metro Transit",
                 url: "https://metro.example.test",
                 timezone: "America/Los_Angeles",
                 coverage: %{
                   lat: 47.53009,
                   lon: -122.1462285,
                   lat_span: 0.681946,
                   lon_span: 0.720787
                 }
               },
               %{
                 id: "40",
                 name: "Regional Transit",
                 url: "https://regional.example.test",
                 timezone: "America/Los_Angeles",
                 coverage: %{lat: 47.6, lon: -122.3, lat_span: 0.5, lon_span: 0.4}
               }
             ]
    end

    test "returns an empty list when no agency has coverage" do
      stub_fixture("agencies_with_coverage_empty")

      assert fetch() == {:ok, []}
    end

    test "sends the key parameter to the agencies-with-coverage JSON endpoint" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:request, conn.request_path, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, fixture("agencies_with_coverage_empty"))
      end)

      assert {:ok, []} = fetch()
      assert_received {:request, "/api/where/agencies-with-coverage.json", %{"key" => @api_key}}
    end
  end

  describe "fetch_response/2" do
    @fetched_at ~U[2026-10-02 03:15:00.123456Z]

    defp fetch_response(options \\ []) do
      options = Keyword.merge(@fast_options, [clock: fn -> @fetched_at end] ++ options)
      Agencies.fetch_response(@settings, options)
    end

    test "returns the whole decoded envelope, unknown fields included" do
      stub_fixture("agencies_with_coverage")

      assert {:ok, response} = fetch_response()
      assert response.envelope == JSON.decode!(fixture("agencies_with_coverage"))
    end

    test "returns the same agencies as fetch/2" do
      stub_fixture("agencies_with_coverage")

      assert {:ok, response} = fetch_response()
      assert {:ok, response.agencies} == fetch()
    end

    test "returns the time the clock reports" do
      stub_fixture("agencies_with_coverage_empty")

      assert {:ok, %{fetched_at: @fetched_at}} = fetch_response()
    end

    test "returns the HTTP status, the method, and the host" do
      stub_fixture("agencies_with_coverage_empty")

      assert {:ok, %{http_status: 200, method: "GET", host: "oba.example.test"}} =
               fetch_response()
    end

    test "replaces a key echoed anywhere in the envelope" do
      body =
        "agencies_with_coverage"
        |> fixture()
        |> String.replace("Metro Transit", "Metro #{@api_key}")

      stub_body(body)

      assert {:ok, response} = fetch_response()
      refute inspect(response, limit: :infinity) =~ @api_key
    end

    for {name, fixture_name, status, error} <- [
          {"a 500 response", "server_error", 500, {:http_status, 500}},
          {"a 401 response", "unauthorized", 401, {:http_status, 401}},
          {"an API-level error", "api_error", 200,
           {:api_error, %{code: 400, text: "invalid parameter"}}}
        ] do
      test "returns the same error as fetch/2 for #{name}" do
        stub_fixture(unquote(fixture_name), unquote(status))

        assert fetch_response() == {:error, unquote(Macro.escape(error))}
      end
    end

    test "raises for a payload that violates the schema" do
      stub_fixture("agencies_with_coverage_schema_violation")

      assert_raise AssertionError, fn -> fetch_response() end
    end
  end

  describe "fetch/2 value errors" do
    test "returns the status for a 500 response" do
      stub_fixture("server_error", 500)

      assert fetch() == {:error, {:http_status, 500}}
    end

    for status <- [401, 403] do
      test "returns the status for a #{status} response" do
        stub_fixture("unauthorized", unquote(status))

        assert fetch() == {:error, {:http_status, unquote(status)}}
      end
    end

    test "returns the envelope code and text for an API-level error on HTTP 200" do
      stub_fixture("api_error")

      assert fetch() == {:error, {:api_error, %{code: 400, text: "invalid parameter"}}}
    end

    test "returns invalid_json for a malformed body" do
      stub_body("<html>not json")

      assert fetch() == {:error, :invalid_json}
    end

    test "returns the status for an unexpected redirect without following it" do
      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.test/")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert fetch() == {:error, {:unexpected_redirect, 302}}
    end

    test "returns the transport reason for a timeout" do
      Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :timeout))

      assert fetch() == {:error, {:transport, :timeout}}
    end

    test "returns deadline_exceeded when the total deadline elapses" do
      Req.Test.stub(@stub_name, fn conn ->
        Process.sleep(500)
        Plug.Conn.send_resp(conn, 200, fixture("agencies_with_coverage_empty"))
      end)

      assert fetch(deadline_ms: 20) == {:error, :deadline_exceeded}
    end
  end

  describe "fetch/2 retries" do
    test "retries a transient 500 and returns the later success" do
      attempts = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) == 1 do
          Plug.Conn.send_resp(conn, 500, fixture("server_error"))
        else
          Plug.Conn.send_resp(conn, 200, fixture("agencies_with_coverage_empty"))
        end
      end)

      assert fetch(max_retries: 1) == {:ok, []}
      assert :counters.get(attempts, 1) == 2
    end

    test "does not retry a 401" do
      attempts = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(attempts, 1, 1)
        Plug.Conn.send_resp(conn, 401, fixture("unauthorized"))
      end)

      assert fetch(max_retries: 2) == {:error, {:http_status, 401}}
      assert :counters.get(attempts, 1) == 1
    end
  end

  describe "fetch/2 assertions on malformed payloads" do
    test "raises when a list entry has no matching agency reference" do
      stub_fixture("agencies_with_coverage_unreferenced")

      assert_raise AssertionError, ~r/no agency reference/, fn -> fetch() end
    end

    test "raises when the payload violates the schema" do
      stub_fixture("agencies_with_coverage_schema_violation")

      assert_raise AssertionError, fn -> fetch() end
    end

    test "raises when limitExceeded is true" do
      stub_fixture("agencies_with_coverage_limit_exceeded")

      assert_raise AssertionError, ~r/limitExceeded/, fn -> fetch() end
    end

    test "raises on a 2xx status other than 200" do
      stub_body("", 204)

      assert_raise AssertionError, ~r/status/, fn -> fetch() end
    end

    test "raises when the envelope code is 200 but the HTTP status is a different 2xx" do
      stub_fixture("agencies_with_coverage_empty", 202)

      assert_raise AssertionError, ~r/status/, fn -> fetch() end
    end
  end

  describe "fetch/2 credential hygiene" do
    test "no returned value or raised message contains the key" do
      echoing_body =
        ~s({"code": 400, "currentTime": 1, "text": "bad key #{@api_key}", "version": 2})

      outcomes = [
        fn -> stub_fixture("agencies_with_coverage") end,
        fn -> stub_fixture("agencies_with_coverage_empty") end,
        fn -> stub_fixture("server_error", 500) end,
        fn -> stub_fixture("unauthorized", 401) end,
        fn -> stub_body(echoing_body) end,
        fn -> stub_body("not json #{@api_key}") end,
        fn -> Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :timeout)) end,
        fn -> stub_fixture("agencies_with_coverage_unreferenced") end
      ]

      for arrange <- outcomes do
        arrange.()

        rendered =
          try do
            inspect(fetch(), limit: :infinity)
          rescue
            exception in AssertionError -> inspect(exception, limit: :infinity)
          end

        refute rendered =~ @api_key
      end
    end
  end

  describe "parse/1" do
    defp data(name), do: name |> fixture() |> JSON.decode!() |> Map.fetch!("data")

    test "returns the agencies of valid data" do
      assert {:ok, [%{id: "1", name: "Metro Transit"}, %{id: "40"}]} =
               Agencies.parse(data("agencies_with_coverage"))
    end

    test "returns the path of a schema mismatch" do
      assert Agencies.parse(data("agencies_with_coverage_schema_violation")) ==
               {:error, {:schema_mismatch, %{path: ["list", 0, "lat"], expected: :required}}}
    end

    test "returns the identifier of a list entry without a reference" do
      assert Agencies.parse(data("agencies_with_coverage_unreferenced")) ==
               {:error, {:unreferenced_agency, "99"}}
    end

    test "returns a schema mismatch when the limit is exceeded" do
      assert {:error, {:schema_mismatch, %{path: ["limitExceeded"]}}} =
               Agencies.parse(data("agencies_with_coverage_limit_exceeded"))
    end

    test "returns the count when it exceeds the bound" do
      entry = %{"agencyId" => "1", "lat" => 1, "lon" => 1, "latSpan" => 1, "lonSpan" => 1}
      reference = %{"id" => "1", "name" => "n", "url" => "u", "timezone" => "t"}

      data = %{
        "limitExceeded" => false,
        "list" => List.duplicate(entry, 1_001),
        "references" => %{"agencies" => [reference]}
      }

      assert Agencies.parse(data) == {:error, {:agency_count_exceeded, 1_001}}
    end

    test "returns a schema mismatch for data that is not a map" do
      assert {:error, {:schema_mismatch, %{path: []}}} = Agencies.parse("text")
    end
  end
end
