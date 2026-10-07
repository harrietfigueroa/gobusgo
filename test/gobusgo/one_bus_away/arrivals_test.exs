defmodule Gobusgo.OneBusAway.ArrivalsTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files
  # cut from a live Puget Sound response for a ferry terminal, whose four
  # arrivals hold a usable prediction, two predictions far from the
  # schedule, and two arrivals with none. Every outcome (success, value
  # errors, raised assertions) is observed through the public contract with
  # no network access.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Arrivals

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @fixture_name "arrivals_and_departures_for_stop"
  @stub_name Arrivals
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %{base_url: "https://oba.example.test", api_key: @api_key}
  @fetched_at ~U[2026-10-07 02:19:53.123456Z]
  @stop_id "95_7"
  @fast_options [
    stop_id: @stop_id,
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
    Arrivals.fetch_response(@settings, Keyword.merge(@fast_options, options))
  end

  defp data(name \\ @fixture_name), do: name |> fixture() |> JSON.decode!() |> Map.fetch!("data")

  # The data of the fixture with its first arrival changed.
  defp data_with_first(change) do
    update_in(data(), ["entry", "arrivalsAndDepartures"], &List.update_at(&1, 0, change))
  end

  defp first_arrival(change) do
    assert {:ok, [arrival | _rest]} = Arrivals.parse(data_with_first(change), @stop_id)
    arrival
  end

  describe "fetch_response/2 success" do
    test "returns every arrival, with a prediction only where the source has a usable one" do
      stub_fixture(@fixture_name)

      assert {:ok, %{arrivals: arrivals}} = fetch_response()

      assert arrivals == [
               %{
                 trip_id: "95_74310062611",
                 service_date_ms: 1_791_270_000_000,
                 stop_sequence: 0,
                 route_id: "95_74",
                 route_short_name: "Seattle - Bremerton",
                 route_long_name: "Seattle - Bremerton",
                 trip_headsign: "Bremerton",
                 arrival_enabled: false,
                 departure_enabled: true,
                 scheduled_arrival_time_ms: 1_791_341_400_000,
                 scheduled_departure_time_ms: 1_791_341_400_000,
                 predicted: true,
                 predicted_arrival_time_ms: nil,
                 predicted_departure_time_ms: nil,
                 vehicle_id: "95_74",
                 vehicle_schedule_deviation_seconds: nil
               },
               %{
                 trip_id: "95_37510062616",
                 service_date_ms: 1_791_270_000_000,
                 stop_sequence: 1,
                 route_id: "95_37",
                 route_short_name: "Bainbridge Island - Seattle",
                 route_long_name: "Bainbridge Island - Seattle",
                 trip_headsign: "Seattle",
                 arrival_enabled: true,
                 departure_enabled: false,
                 scheduled_arrival_time_ms: 1_791_339_300_000,
                 scheduled_departure_time_ms: 1_791_339_300_000,
                 predicted: false,
                 predicted_arrival_time_ms: nil,
                 predicted_departure_time_ms: nil,
                 vehicle_id: nil,
                 vehicle_schedule_deviation_seconds: nil
               },
               %{
                 trip_id: "95_73510062616",
                 service_date_ms: 1_791_270_000_000,
                 stop_sequence: 0,
                 route_id: "95_73",
                 route_short_name: "Seattle - Bainbridge Island",
                 route_long_name: "Seattle - Bainbridge Island",
                 trip_headsign: "Bainbridge Island",
                 arrival_enabled: false,
                 departure_enabled: true,
                 scheduled_arrival_time_ms: 1_791_340_200_000,
                 scheduled_departure_time_ms: 1_791_340_200_000,
                 predicted: false,
                 predicted_arrival_time_ms: nil,
                 predicted_departure_time_ms: nil,
                 vehicle_id: nil,
                 vehicle_schedule_deviation_seconds: 0
               },
               %{
                 trip_id: "95_47310062611",
                 service_date_ms: 1_791_270_000_000,
                 stop_sequence: 1,
                 route_id: "95_47",
                 route_short_name: "Bremerton - Seattle",
                 route_long_name: "Bremerton - Seattle",
                 trip_headsign: "Seattle",
                 arrival_enabled: true,
                 departure_enabled: false,
                 scheduled_arrival_time_ms: 1_791_340_800_000,
                 scheduled_departure_time_ms: 1_791_340_800_000,
                 predicted: true,
                 predicted_arrival_time_ms: 1_791_340_620_000,
                 predicted_departure_time_ms: nil,
                 vehicle_id: "95_74",
                 vehicle_schedule_deviation_seconds: -180
               }
             ]
    end

    test "returns no arrival for a stop that has none in the window" do
      stub_fixture(@fixture_name <> "_empty")

      assert {:ok, %{arrivals: []}} = fetch_response()
    end

    test "returns the whole decoded envelope, unknown fields included" do
      stub_fixture(@fixture_name)

      assert {:ok, %{envelope: envelope}} = fetch_response()
      assert envelope == JSON.decode!(fixture(@fixture_name))
    end

    test "returns the stop, the clock's time, the HTTP status, the method, and the host" do
      stub_fixture(@fixture_name)

      assert {:ok, response} = fetch_response()

      assert Map.take(response, [:stop_id, :fetched_at, :http_status, :method, :host]) == %{
               stop_id: @stop_id,
               fetched_at: @fetched_at,
               http_status: 200,
               method: "GET",
               host: "oba.example.test"
             }
    end

    test "sends the key parameter to the stop's arrivals-and-departures-for-stop JSON endpoint" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, {:request, conn.request_path, URI.decode_query(conn.query_string)})

        body =
          @fixture_name
          |> fixture()
          |> JSON.decode!()
          |> put_in(["data", "entry", "stopId"], "a/b c")
          |> put_in(["data", "entry", "arrivalsAndDepartures"], [])
          |> JSON.encode!()

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, _response} = fetch_response(stop_id: "a/b c")

      assert_received {:request, "/api/where/arrivals-and-departures-for-stop/a%2Fb%20c.json",
                       %{"key" => @api_key}}
    end
  end

  describe "fetch_response/2 value errors" do
    for {name, fixture_name, status, error} <- [
          {"a 500 response", "server_error", 500, {:http_status, 500}},
          {"a 401 response", "unauthorized", 401, {:http_status, 401}},
          {"a stop the server does not know", "unauthorized", 404, {:http_status, 404}},
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
    test "raises when the payload violates the schema" do
      stub_fixture(@fixture_name <> "_schema_violation")

      assert_raise AssertionError, ~r/schema mismatch/, fn -> fetch_response() end
    end

    test "raises when the response is about another stop" do
      stub_fixture(@fixture_name)

      assert_raise AssertionError, ~r/is about stop/, fn -> fetch_response(stop_id: "95_8") end
    end

    test "raises for an empty stop identifier" do
      assert_raise AssertionError, ~r/stop identifier/, fn -> fetch_response(stop_id: "") end
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
        fn -> stub_body(String.replace(fixture(@fixture_name), "Bremerton", @api_key)) end,
        fn -> stub_fixture("unauthorized", 401) end,
        fn -> stub_body(echoing_body) end,
        fn -> stub_body("not json #{@api_key}") end,
        fn -> stub_fixture(@fixture_name <> "_schema_violation") end
      ]

      for stub <- outcomes do
        stub.()

        rendered =
          try do
            inspect(fetch_response(), limit: :infinity, printable_limit: :infinity)
          rescue
            error in AssertionError -> Exception.message(error) <> inspect(error.cause)
          end

        refute rendered =~ @api_key
      end
    end
  end

  describe "parse/2 prediction" do
    # Each case changes the first arrival of the fixture, which is scheduled
    # to arrive and to depart at 1,791,341,400,000.
    @scheduled_time_ms 1_791_341_400_000

    for {name, offset_ms, usable?} <- [
          {"at the scheduled time", 0, true},
          {"two hours after the scheduled time", 7_200_000, true},
          {"two hours before the scheduled time", -7_200_000, true},
          {"one millisecond past two hours after", 7_200_001, false},
          {"one millisecond past two hours before", -7_200_001, false}
        ] do
      test "is #{if usable?, do: "kept", else: "absent"} for a predicted time #{name}" do
        predicted_time_ms = @scheduled_time_ms + unquote(offset_ms)
        arrival = first_arrival(&Map.put(&1, "predictedArrivalTime", predicted_time_ms))

        expected =
          case unquote(usable?) do
            true -> predicted_time_ms
            false -> nil
          end

        assert arrival.predicted_arrival_time_ms == expected
      end
    end

    test "is absent for a predicted time of zero" do
      arrival = first_arrival(&Map.put(&1, "predictedArrivalTime", 0))

      assert %{predicted: true, predicted_arrival_time_ms: nil} = arrival
    end

    test "is absent when the source says it has no real-time data, whatever the time" do
      arrival =
        first_arrival(
          &Map.merge(&1, %{"predicted" => false, "predictedArrivalTime" => @scheduled_time_ms})
        )

      assert %{predicted: false, predicted_arrival_time_ms: nil} = arrival
    end

    test "is judged for the departure apart from the arrival" do
      arrival =
        first_arrival(
          &Map.merge(&1, %{
            "predictedArrivalTime" => @scheduled_time_ms + 60_000,
            "predictedDepartureTime" => 0
          })
        )

      assert arrival.predicted_arrival_time_ms == @scheduled_time_ms + 60_000
      assert arrival.predicted_departure_time_ms == nil
    end
  end

  describe "parse/2 vehicle" do
    test "comes with its schedule deviation when the vehicle serves the arrival's trip" do
      arrival =
        first_arrival(fn arrival ->
          Map.update!(
            arrival,
            "tripStatus",
            &Map.merge(&1, %{"activeTripId" => arrival["tripId"], "scheduleDeviation" => 95})
          )
        end)

      assert arrival.vehicle_schedule_deviation_seconds == 95
    end

    test "comes with no schedule deviation while the vehicle serves another trip" do
      assert first_arrival(& &1).vehicle_schedule_deviation_seconds == nil
    end

    test "comes with no schedule deviation for an arrival without a trip status" do
      arrival = first_arrival(&Map.delete(&1, "tripStatus"))

      assert arrival.vehicle_schedule_deviation_seconds == nil
    end

    test "is absent for an empty vehicle identifier" do
      assert first_arrival(&Map.put(&1, "vehicleId", "")).vehicle_id == nil
    end
  end

  describe "parse/2 names" do
    for {field, key} <- [
          {"routeShortName", :route_short_name},
          {"routeLongName", :route_long_name},
          {"tripHeadsign", :trip_headsign}
        ] do
      test "has no #{key} when the source sends #{field} empty" do
        arrival = first_arrival(&Map.put(&1, unquote(field), ""))

        assert Map.fetch!(arrival, unquote(key)) == nil
      end
    end
  end

  describe "parse/2" do
    test "returns the arrivals of valid data" do
      assert {:ok, [%{trip_id: "95_74310062611"}, %{}, %{}, %{}]} =
               Arrivals.parse(data(), @stop_id)
    end

    test "keeps two arrivals of one trip, one per vehicle" do
      data =
        update_in(data(), ["entry", "arrivalsAndDepartures"], fn [arrival | _rest] ->
          [arrival, Map.put(arrival, "vehicleId", "95_75")]
        end)

      assert {:ok, [%{vehicle_id: "95_74"}, %{vehicle_id: "95_75"}]} =
               Arrivals.parse(data, @stop_id)
    end

    test "returns the path of a schema mismatch" do
      assert Arrivals.parse(data(@fixture_name <> "_schema_violation"), @stop_id) ==
               {:error,
                {:schema_mismatch,
                 %{
                   path: ["entry", "arrivalsAndDepartures", 0, "scheduledArrivalTime"],
                   expected: :required
                 }}}
    end

    test "returns the stop of a response about another stop" do
      assert Arrivals.parse(data(), "95_8") == {:error, {:stop_mismatch, "95_7"}}
    end

    test "returns the count when it exceeds the bound" do
      data =
        update_in(data(), ["entry", "arrivalsAndDepartures"], fn [arrival | _rest] ->
          List.duplicate(arrival, 501)
        end)

      assert Arrivals.parse(data, @stop_id) == {:error, {:arrival_count_exceeded, 501}}
    end

    for {name, field, value} <- [
          {"an arrival at another stop", "stopId", "95_8"},
          {"an empty trip identifier", "tripId", ""},
          {"an empty route identifier", "routeId", ""},
          {"a service date of zero", "serviceDate", 0},
          {"a scheduled arrival time of zero", "scheduledArrivalTime", 0},
          {"a negative scheduled departure time", "scheduledDepartureTime", -1},
          {"a negative stop sequence", "stopSequence", -1}
        ] do
      test "returns invalid_arrival for #{name}" do
        data = data_with_first(&Map.put(&1, unquote(field), unquote(value)))

        assert Arrivals.parse(data, @stop_id) == {:error, {:invalid_arrival, 0}}
      end
    end

    for {name, field, value} <- [
          {"a predicted time with a fraction", "predictedArrivalTime", 1.5},
          {"a predicted flag that is not a boolean", "predicted", "yes"},
          {"a vehicle identifier that is not a string", "vehicleId", nil}
        ] do
      test "returns a schema mismatch for #{name}" do
        data = data_with_first(&Map.put(&1, unquote(field), unquote(value)))
        path = ["entry", "arrivalsAndDepartures", 0, unquote(field)]

        assert {:error, {:schema_mismatch, %{path: ^path}}} = Arrivals.parse(data, @stop_id)
      end
    end

    test "returns a schema mismatch for data that is not a map" do
      assert {:error, {:schema_mismatch, %{path: []}}} = Arrivals.parse("text", @stop_id)
    end
  end
end
