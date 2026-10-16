defmodule Gobusgo.OneBusAway.RoutesTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files
  # cut from a live Puget Sound response, so every outcome (success, value
  # errors, raised assertions) is observed through the public contract with
  # no network access.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Routes

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name Routes
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %Gobusgo.Config.OneBusAway{base_url: "https://oba.example.test", api_key: @api_key}
  @fetched_at ~U[2026-10-05 01:17:31.123456Z]
  @fast_options [
    agency_id: "40",
    clock: &__MODULE__.fetched_at/0,
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

  def fetched_at, do: @fetched_at

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp stub_body(body, status \\ 200) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp stub_fixture(name, status \\ 200), do: stub_body(fixture(name), status)

  defp fetch_response(options \\ []) do
    Routes.fetch_response(@settings, Keyword.merge(@fast_options, options))
  end

  defp data(name), do: name |> fixture() |> JSON.decode!() |> Map.fetch!("data")

  defp parse(data), do: Routes.parse(data, "40")

  describe "fetch_response/2 success" do
    test "returns every route of the agency in response order" do
      stub_fixture("routes_for_agency")

      assert {:ok, %{routes: routes}} = fetch_response()

      assert routes == [
               %{
                 id: "40_SNDR_EV",
                 agency_id: "40",
                 short_name: "N Line",
                 long_name: "Everett - Seattle",
                 description:
                   "N Line runs between Everett Station and King Street Station weekdays",
                 type: 2,
                 color: "9AB6D3",
                 text_color: "000000",
                 url: "https://www.soundtransit.org/N"
               },
               %{
                 id: "40_100511",
                 agency_id: "40",
                 short_name: "542",
                 long_name: nil,
                 description: "Redmond - University District",
                 type: 3,
                 color: "2B376E",
                 text_color: "FFFFFF",
                 url: "https://www.soundtransit.org/542"
               },
               %{
                 id: "40_100479",
                 agency_id: "40",
                 short_name: "1 Line",
                 long_name: "Lynnwood - Federal Way",
                 description:
                   "1 Line runs between Lynnwood City Center Station and Federal Way Downtown Station seven days a week",
                 type: 0,
                 color: "28813F",
                 text_color: "FFFFFF",
                 url: "https://www.soundtransit.org/1"
               }
             ]
    end

    test "returns an empty list when the agency has no routes" do
      stub_fixture("routes_for_agency_empty")

      assert {:ok, %{routes: []}} = fetch_response()
    end

    test "returns the whole decoded envelope, unknown fields included" do
      stub_fixture("routes_for_agency")

      assert {:ok, response} = fetch_response()
      assert response.envelope == JSON.decode!(fixture("routes_for_agency"))
    end

    test "returns the agency, the clock's time, the HTTP status, the method, and the host" do
      stub_fixture("routes_for_agency_empty")

      assert {:ok,
              %{
                agency_id: "40",
                fetched_at: @fetched_at,
                http_status: 200,
                method: "GET",
                host: "oba.example.test"
              }} = fetch_response()
    end

    test "sends the key parameter to the agency's routes-for-agency JSON endpoint" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:request, conn.request_path, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, fixture("routes_for_agency_empty"))
      end)

      assert {:ok, _response} = fetch_response(agency_id: "a/b c")

      assert_received {:request, "/api/where/routes-for-agency/a%2Fb%20c.json",
                       %{"key" => @api_key}}
    end
  end

  describe "fetch_response/2 value errors" do
    for {name, fixture_name, status, error} <- [
          {"a 500 response", "server_error", 500, {:http_status, 500}},
          {"a 401 response", "unauthorized", 401, {:http_status, 401}},
          {"a 404 response", "unauthorized", 404, {:http_status, 404}},
          {"an API-level error", "api_error", 200,
           {:api_error, %{code: 400, text: "invalid parameter"}}}
        ] do
      test "returns the error for #{name}" do
        stub_fixture(unquote(fixture_name), unquote(status))

        assert fetch_response() == {:error, unquote(Macro.escape(error))}
      end
    end

    test "returns invalid_json for a malformed body" do
      stub_body("<html>not json")

      assert fetch_response() == {:error, :invalid_json}
    end

    test "returns the transport reason for a timeout" do
      Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :timeout))

      assert fetch_response() == {:error, {:transport, :timeout}}
    end
  end

  describe "fetch_response/2 assertions" do
    for {name, fixture_name, message} <- [
          {"the payload violates the schema", "routes_for_agency_schema_violation",
           ~r/schema mismatch/},
          {"limitExceeded is true", "routes_for_agency_limit_exceeded", ~r/limitExceeded/},
          {"a route identifier repeats", "routes_for_agency_duplicate_route", ~r/repeats/}
        ] do
      test "raises when #{name}" do
        stub_fixture(unquote(fixture_name))

        assert_raise AssertionError, unquote(Macro.escape(message)), fn -> fetch_response() end
      end
    end

    test "raises when a route belongs to another agency than the one asked for" do
      stub_fixture("routes_for_agency")

      assert_raise AssertionError, ~r/route at index 0/, fn -> fetch_response(agency_id: "1") end
    end

    test "raises for an empty agency identifier" do
      assert_raise AssertionError, ~r/agency identifier/, fn -> fetch_response(agency_id: "") end
    end

    test "raises on a 2xx status other than 200" do
      stub_body("", 204)

      assert_raise AssertionError, ~r/status/, fn -> fetch_response() end
    end
  end

  describe "fetch_response/2 credential hygiene" do
    test "no returned value or raised message contains the key" do
      echoing_body =
        ~s({"code": 400, "currentTime": 1, "text": "bad key #{@api_key}", "version": 2})

      outcomes = [
        fn -> stub_body(String.replace(fixture("routes_for_agency"), "542", @api_key)) end,
        fn -> stub_fixture("unauthorized", 401) end,
        fn -> stub_body(echoing_body) end,
        fn -> stub_body("not json #{@api_key}") end,
        fn -> stub_fixture("routes_for_agency_schema_violation") end
      ]

      for arrange <- outcomes do
        arrange.()

        rendered =
          try do
            inspect(fetch_response(), limit: :infinity)
          rescue
            exception in AssertionError -> inspect(exception, limit: :infinity)
          end

        refute rendered =~ @api_key
      end
    end
  end

  describe "parse/2 empty fields" do
    # Each case empties one field of the fixture's first route, the way the
    # live server sends a field the agency did not supply.
    for {name, field, key} <- [
          {"short name", "shortName", :short_name},
          {"long name", "longName", :long_name},
          {"description", "description", :description},
          {"color", "color", :color},
          {"text color", "textColor", :text_color},
          {"address", "url", :url}
        ] do
      test "returns no #{name} when the route's is empty" do
        data = data("routes_for_agency")
        list = List.update_at(data["list"], 0, &Map.put(&1, unquote(field), ""))

        assert {:ok, [route | _rest]} = parse(Map.put(data, "list", list))
        assert Map.fetch!(route, unquote(key)) == nil
      end
    end
  end

  describe "parse/2" do
    test "returns the routes of valid data" do
      assert {:ok, [%{id: "40_SNDR_EV"}, %{id: "40_100511"}, %{id: "40_100479"}]} =
               parse(data("routes_for_agency"))
    end

    test "returns the path of a schema mismatch" do
      assert parse(data("routes_for_agency_schema_violation")) ==
               {:error, {:schema_mismatch, %{path: ["list", 0, "type"], expected: :required}}}
    end

    test "returns a schema mismatch when the limit is exceeded" do
      assert {:error, {:schema_mismatch, %{path: ["limitExceeded"]}}} =
               parse(data("routes_for_agency_limit_exceeded"))
    end

    test "returns the identifier of a repeated route" do
      assert parse(data("routes_for_agency_duplicate_route")) ==
               {:error, {:duplicate_route, "40_SNDR_EV"}}
    end

    test "returns the count when it exceeds the bound" do
      [route | _routes] = data("routes_for_agency")["list"]

      list =
        for index <- 1..1_001 do
          Map.put(route, "id", "40_#{index}")
        end

      data = Map.put(data("routes_for_agency_empty"), "list", list)

      assert parse(data) == {:error, {:route_count_exceeded, 1_001}}
    end

    for {name, field, value} <- [
          {"an empty route identifier", "id", ""},
          {"another agency", "agencyId", "1"},
          {"a color that is not six hexadecimal digits", "color", "#9AB6D3"},
          {"a text color that is not six hexadecimal digits", "textColor", "black"}
        ] do
      test "returns invalid_route for #{name}" do
        data = data("routes_for_agency")
        list = List.update_at(data["list"], 1, &Map.put(&1, unquote(field), unquote(value)))

        assert parse(Map.put(data, "list", list)) == {:error, {:invalid_route, 1}}
      end
    end

    test "returns a schema mismatch for a route type that is not an integer" do
      data = data("routes_for_agency")
      list = List.update_at(data["list"], 0, &Map.put(&1, "type", 3.5))

      assert parse(Map.put(data, "list", list)) ==
               {:error, {:schema_mismatch, %{path: ["list", 0, "type"], expected: :integer}}}
    end

    test "returns a schema mismatch for data that is not a map" do
      assert {:error, {:schema_mismatch, %{path: []}}} = parse("text")
    end
  end
end
