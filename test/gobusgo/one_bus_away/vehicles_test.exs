defmodule Gobusgo.OneBusAway.VehiclesTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files
  # cut from a live Puget Sound response, so every outcome (success, value
  # errors, raised assertions) is observed through the public contract with
  # no network access.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.Vehicles

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name Vehicles
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %{base_url: "https://oba.example.test", api_key: @api_key}
  @fetched_at ~U[2026-10-02 03:15:00.123456Z]
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
    Vehicles.fetch_response(@settings, Keyword.merge(@fast_options, options))
  end

  defp data(name), do: name |> fixture() |> JSON.decode!() |> Map.fetch!("data")

  describe "fetch_response/2 success" do
    test "returns every vehicle mapped from the vehicle and its trip status" do
      stub_fixture("vehicles_for_agency")

      assert {:ok, %{vehicles: vehicles}} = fetch_response()

      assert vehicles == [
               %{
                 id: "40_41605",
                 active_trip_id: "40_1655020",
                 position: %{lat: 47.316389, lon: -122.304008},
                 orientation: 176.51420881742143,
                 last_known_location: %{lat: 47.3177375793457, lon: -122.2967300415039},
                 last_known_orientation: 338.1999969482422,
                 last_update_time_ms: 1_790_985_888_000,
                 last_location_update_time_ms: 1_790_985_895_000,
                 predicted: true
               },
               %{
                 id: "40_H:121:0:Weekday:1:26SEP:52043:12345",
                 active_trip_id: "40_16687274__H:121:0:Weekday:1:26SEP:52043:12345",
                 position: %{lat: 47.815963, lon: -122.296309},
                 orientation: 359.4195995112881,
                 last_known_location: nil,
                 last_known_orientation: 0,
                 last_update_time_ms: 1_790_985_877_000,
                 last_location_update_time_ms: 0,
                 predicted: true
               },
               %{
                 id: "40_9636",
                 active_trip_id: nil,
                 position: nil,
                 orientation: nil,
                 last_known_location: %{lat: 47.613616943359375, lon: -122.20159912109375},
                 last_known_orientation: nil,
                 last_update_time_ms: 1_790_970_852_000,
                 last_location_update_time_ms: 1_790_970_852_000,
                 predicted: nil
               },
               %{
                 id: "40_H:121:0:Weekday:1:26SEP:52006:12345",
                 active_trip_id: nil,
                 position: nil,
                 orientation: nil,
                 last_known_location: nil,
                 last_known_orientation: nil,
                 last_update_time_ms: 1_790_984_286_000,
                 last_location_update_time_ms: 0,
                 predicted: nil
               }
             ]
    end

    test "returns vehicles the vehicle records accept" do
      stub_fixture("vehicles_for_agency")

      assert {:ok, %{vehicles: vehicles}} = fetch_response()

      fetch = %{
        agency_id: "40",
        destination: "raw/oba/vehicles-for-agency/example.json",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("0", 64),
        request_id: Gobusgo.RequestId.generate(),
        vehicles: vehicles
      }

      assert %{vehicles: records} = Records.build(fetch)
      assert length(records) == length(vehicles)
    end

    test "returns an empty list when the agency has no vehicles" do
      stub_fixture("vehicles_for_agency_empty")

      assert {:ok, %{vehicles: []}} = fetch_response()
    end

    test "returns the whole decoded envelope, unknown fields included" do
      stub_fixture("vehicles_for_agency")

      assert {:ok, response} = fetch_response()
      assert response.envelope == JSON.decode!(fixture("vehicles_for_agency"))
    end

    test "returns the agency, the clock's time, the HTTP status, the method, and the host" do
      stub_fixture("vehicles_for_agency_empty")

      assert {:ok,
              %{
                agency_id: "40",
                fetched_at: @fetched_at,
                http_status: 200,
                method: "GET",
                host: "oba.example.test"
              }} = fetch_response()
    end

    test "sends the key parameter to the agency's vehicles-for-agency JSON endpoint" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:request, conn.request_path, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, fixture("vehicles_for_agency_empty"))
      end)

      assert {:ok, _response} = fetch_response(agency_id: "a/b c")

      assert_received {:request, "/api/where/vehicles-for-agency/a%2Fb%20c.json",
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
          {"the payload violates the schema", "vehicles_for_agency_schema_violation",
           ~r/schema mismatch/},
          {"limitExceeded is true", "vehicles_for_agency_limit_exceeded", ~r/limitExceeded/},
          {"a vehicle identifier repeats", "vehicles_for_agency_duplicate_vehicle", ~r/repeats/}
        ] do
      test "raises when #{name}" do
        stub_fixture(unquote(fixture_name))

        assert_raise AssertionError, unquote(Macro.escape(message)), fn -> fetch_response() end
      end
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
        fn -> stub_body(String.replace(fixture("vehicles_for_agency"), "40_9636", @api_key)) end,
        fn -> stub_fixture("unauthorized", 401) end,
        fn -> stub_body(echoing_body) end,
        fn -> stub_body("not json #{@api_key}") end,
        fn -> stub_fixture("vehicles_for_agency_schema_violation") end
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

  describe "parse/1" do
    test "returns the vehicles of valid data" do
      assert {:ok, [%{id: "40_41605"}, %{}, %{}, %{}]} =
               Vehicles.parse(data("vehicles_for_agency"))
    end

    test "returns the path of a schema mismatch" do
      assert Vehicles.parse(data("vehicles_for_agency_schema_violation")) ==
               {:error,
                {:schema_mismatch, %{path: ["list", 0, "lastUpdateTime"], expected: :required}}}
    end

    test "returns a schema mismatch when the limit is exceeded" do
      assert {:error, {:schema_mismatch, %{path: ["limitExceeded"]}}} =
               Vehicles.parse(data("vehicles_for_agency_limit_exceeded"))
    end

    test "returns the identifier of a repeated vehicle" do
      assert Vehicles.parse(data("vehicles_for_agency_duplicate_vehicle")) ==
               {:error, {:duplicate_vehicle, "40_41605"}}
    end

    test "returns the count when it exceeds the bound" do
      [vehicle | _vehicles] = data("vehicles_for_agency")["list"]

      list =
        for index <- 1..5_001 do
          Map.put(vehicle, "vehicleId", "40_#{index}")
        end

      data = Map.put(data("vehicles_for_agency_empty"), "list", list)

      assert Vehicles.parse(data) == {:error, {:vehicle_count_exceeded, 5_001}}
    end

    for {name, path, value} <- [
          {"an empty vehicle identifier", ["vehicleId"], ""},
          {"a negative update time", ["lastUpdateTime"], -1},
          {"a negative location update time", ["lastLocationUpdateTime"], -1}
        ] do
      test "returns invalid_vehicle for #{name}" do
        data = data("vehicles_for_agency")
        list = List.update_at(data["list"], 0, &put_in(&1, unquote(path), unquote(value)))

        assert Vehicles.parse(Map.put(data, "list", list)) == {:error, {:invalid_vehicle, 0}}
      end
    end

    test "returns a schema mismatch for a trip status without a position" do
      data = data("vehicles_for_agency")
      list = List.update_at(data["list"], 0, &(pop_in(&1, ["tripStatus", "position"]) |> elem(1)))

      assert Vehicles.parse(Map.put(data, "list", list)) ==
               {:error,
                {:schema_mismatch,
                 %{path: ["list", 0, "tripStatus", "position"], expected: :required}}}
    end

    test "returns a schema mismatch for data that is not a map" do
      assert {:error, {:schema_mismatch, %{path: []}}} = Vehicles.parse("text")
    end
  end
end
