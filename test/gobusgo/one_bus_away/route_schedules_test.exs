defmodule Gobusgo.OneBusAway.RouteSchedulesTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files
  # cut from a live Puget Sound response of a night route, so every outcome
  # (a schedule, a day without service, value errors, raised assertions) is
  # observed through the public contract with no network access. The parse
  # cases change one part of that response each.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RouteSchedules

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RouteSchedules
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %Gobusgo.Config.OneBusAway{base_url: "https://oba.example.test", api_key: @api_key}
  @fetched_at ~U[2026-11-08 01:15:30.123456Z]
  @route_id "19_41"
  @service_date ~D[2026-11-07]
  @fast_options [
    route_id: @route_id,
    service_date: @service_date,
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

  defp stub_fixture(name, status \\ 200) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, fixture(name))
    end)
  end

  defp fetch_response(options \\ []) do
    RouteSchedules.fetch_response(@settings, Keyword.merge(@fast_options, options))
  end

  defp data, do: "schedule_for_route" |> fixture() |> JSON.decode!() |> Map.fetch!("data")

  defp parse(data), do: RouteSchedules.parse(data, @route_id)

  defp first_trip_path,
    do: ["entry", "stopTripGroupings", Access.at(0), "tripsWithStopTimes", Access.at(0)]

  defp stop_time_path(index), do: first_trip_path() ++ ["stopTimes", Access.at(index)]

  describe "fetch_response/2 schedule" do
    test "returns the route's trips for the service date, each with its stop times" do
      stub_fixture("schedule_for_route")

      assert {:ok, %{schedule: schedule}} = fetch_response()
      assert %{route_id: "19_41", schedule_date_ms: 1_794_038_400_000} = schedule
      assert schedule.service_ids == ["19_7-v43"]
      assert Enum.map(schedule.trips, & &1.id) == ["19_t12C-b19B-sl7-v43", "19_t21-b19B-sl7-v43"]

      [trip | _rest] = schedule.trips

      assert %{
               direction_id: "0",
               headsign: "To Evergreen State College",
               block_id: "19_411-v43",
               service_id: "19_7-v43",
               shape_id: "19_16394_shp-v43"
             } = trip

      assert length(trip.stop_times) == 32
    end

    test "gives each stop time its stop, its times in seconds of the service day, and its flags" do
      stub_fixture("schedule_for_route")

      assert {:ok, %{schedule: %{trips: [trip | _rest]}}} = fetch_response()
      expected = data() |> get_in(stop_time_path(0))

      assert hd(trip.stop_times) == %{
               stop_id: expected["stopId"],
               arrival_s: expected["arrivalTime"],
               departure_s: expected["departureTime"],
               arrival_enabled: true,
               departure_enabled: true
             }
    end

    test "keeps a stop time past midnight in seconds of the service day it belongs to" do
      stub_fixture("schedule_for_route")

      assert {:ok, %{schedule: %{trips: [trip | _rest]}}} = fetch_response()
      assert List.last(trip.stop_times).departure_s == 98_700
    end

    test "asks for the service date it is given" do
      test_process = self()

      Req.Test.stub(@stub_name, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_process, {:query, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, fixture("schedule_for_route"))
      end)

      assert {:ok, _response} = fetch_response()
      assert_received {:query, %{"date" => "2026-11-07"}}
    end

    test "returns the route, the service date, and the facts of the retrieval" do
      stub_fixture("schedule_for_route")

      assert {:ok, response} = fetch_response()

      assert %{
               route_id: "19_41",
               service_date: ~D[2026-11-07],
               fetched_at: @fetched_at,
               http_status: 200,
               method: "GET",
               host: "oba.example.test"
             } = response
    end
  end

  describe "fetch_response/2 without service" do
    # https://developer.onebusaway.org/api/where/methods/schedule-for-route — checked 2026-11-08
    test "returns no schedule for a route with no service on the date, code 510" do
      stub_fixture("schedule_for_route_no_service")

      assert {:ok, %{schedule: :no_service, route_id: "19_41", service_date: ~D[2026-11-07]}} =
               fetch_response()
    end
  end

  describe "fetch_response/2 errors" do
    test "returns another envelope code as an API error" do
      stub_fixture("api_error")

      assert {:error, {:api_error, %{code: 400}}} = fetch_response()
    end

    test "raises for a schedule that breaks the contract" do
      Req.Test.stub(@stub_name, fn conn ->
        body =
          "schedule_for_route"
          |> fixture()
          |> JSON.decode!()
          |> put_in(["data" | stop_time_path(0)] ++ ["arrivalTime"], "early")
          |> JSON.encode!()

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert_raise AssertionError, fn -> fetch_response() end
    end
  end

  describe "parse/2" do
    test "accepts the fixture" do
      assert {:ok, %{route_id: "19_41"}} = parse(data())
    end

    test "returns a mismatch for a response of another route" do
      assert parse(put_in(data(), ["entry", "routeId"], "19_42")) ==
               {:error, {:route_mismatch, "19_42"}}
    end

    test "returns a schema mismatch for a time that is not an integer" do
      changed = put_in(data(), stop_time_path(0) ++ ["arrivalTime"], 1.5)

      assert {:error, {:schema_mismatch, _mismatch}} = parse(changed)
    end

    test "returns the trip whose stop times name another trip" do
      changed = put_in(data(), stop_time_path(3) ++ ["tripId"], "19_other")

      assert parse(changed) == {:error, {:stop_time_trip_mismatch, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns the trip that has no reference" do
      changed = update_in(data(), ["references", "trips"], &tl/1)

      assert parse(changed) == {:error, {:unreferenced_trip, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns a trip listed twice" do
      [trip] = get_in(data(), ["entry", "stopTripGroupings", Access.at(0), "tripsWithStopTimes"])

      changed =
        put_in(data(), ["entry", "stopTripGroupings", Access.at(0), "tripsWithStopTimes"], [
          trip,
          trip
        ])

      assert parse(changed) == {:error, {:duplicate_trip, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns the stop time that arrives after it departs" do
      changed =
        update_in(data(), stop_time_path(2), fn stop_time ->
          %{stop_time | "arrivalTime" => stop_time["departureTime"] + 1}
        end)

      assert parse(changed) == {:error, {:arrival_after_departure, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns the trip whose stop times go back in time" do
      changed =
        update_in(data(), stop_time_path(5), fn stop_time ->
          %{stop_time | "arrivalTime" => 0, "departureTime" => 0}
        end)

      assert parse(changed) == {:error, {:unordered_stop_times, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns the trip with a time past the service day's bound" do
      last = 31

      changed =
        update_in(data(), stop_time_path(last), fn stop_time ->
          %{stop_time | "arrivalTime" => 200_000, "departureTime" => 200_000}
        end)

      assert parse(changed) == {:error, {:time_out_of_range, "19_t12C-b19B-sl7-v43"}}
    end

    test "returns the trip with no stop times" do
      changed = put_in(data(), first_trip_path() ++ ["stopTimes"], [])

      assert parse(changed) == {:error, {:stop_time_count_out_of_range, "19_t12C-b19B-sl7-v43"}}
    end
  end
end
