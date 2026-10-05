defmodule Gobusgo.OneBusAway.RoutePathsTest do
  # Drives the requester through Req.Test stubs that serve JSON fixture files
  # cut from a live Puget Sound response, so every outcome (success, value
  # errors, raised assertions) is observed through the public contract with
  # no network access. The parse cases change one part of that response each.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RoutePaths

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RoutePaths
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %{base_url: "https://oba.example.test", api_key: @api_key}
  @fetched_at ~U[2026-10-05 01:59:49.123456Z]
  @route_id "1_100336"
  @fast_options [
    route_id: @route_id,
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
    RoutePaths.fetch_response(@settings, Keyword.merge(@fast_options, options))
  end

  defp data, do: "stops_for_route" |> fixture() |> JSON.decode!() |> Map.fetch!("data")

  defp parse(data), do: RoutePaths.parse(data, @route_id)

  defp group_path, do: ["entry", "stopGroupings", Access.at(0), "stopGroups", Access.at(0)]

  describe "fetch_response/2 success" do
    test "returns the route's stops, groups, and paths" do
      stub_fixture("stops_for_route")

      assert {:ok, %{route_path: route_path}} = fetch_response()

      assert route_path == %{
               route_id: "1_100336",
               stop_ids: ["1_1889", "1_99997"],
               polylines: [%{points: "mbpaHphuiVJVbhAn|F", point_count: 3, levels: nil}],
               stop_groupings: [
                 %{
                   type: "direction",
                   ordered: true,
                   stop_groups: [
                     %{
                       id: "1",
                       name: "Downtown Seattle Water Taxi",
                       names: ["Downtown Seattle Water Taxi"],
                       name_type: "destination",
                       stop_ids: ["1_99997", "1_1889"],
                       polylines: [%{points: "}xmaHxf}iVchAo|FKW", point_count: 3, levels: nil}]
                     },
                     %{
                       id: "0",
                       name: "West Seattle Water Taxi",
                       names: ["West Seattle Water Taxi"],
                       name_type: "destination",
                       stop_ids: ["1_1889", "1_99997"],
                       polylines: [%{points: "mbpaHphuiVJVbhAn|F", point_count: 3, levels: nil}]
                     }
                   ]
                 }
               ],
               stops: [
                 %{
                   id: "1_1889",
                   name: "Vashon Island Water Taxi & Colman Dock",
                   lat: 47.601223,
                   lon: -122.338928,
                   code: "1889",
                   direction: nil,
                   location_type: 0,
                   parent: nil,
                   wheelchair_boarding: "ACCESSIBLE",
                   route_ids: ["1_100336", "1_100337"]
                 },
                 %{
                   id: "1_99997",
                   name: "Water Taxi Route & Harbor Ave SW",
                   lat: 47.589374,
                   lon: -122.37944,
                   code: "99997",
                   direction: nil,
                   location_type: 0,
                   parent: nil,
                   wheelchair_boarding: "UNKNOWN",
                   route_ids: ["1_100336"]
                 }
               ]
             }
    end

    test "returns the whole decoded envelope, unknown fields included" do
      stub_fixture("stops_for_route")

      assert {:ok, response} = fetch_response()
      assert response.envelope == JSON.decode!(fixture("stops_for_route"))
    end

    test "returns the route, the clock's time, the HTTP status, the method, and the host" do
      stub_fixture("stops_for_route")

      assert {:ok,
              %{
                route_id: @route_id,
                fetched_at: @fetched_at,
                http_status: 200,
                method: "GET",
                host: "oba.example.test"
              }} = fetch_response()
    end

    test "asks the route's stops-for-route JSON endpoint for polylines, with the key" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:request, conn.request_path, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, fixture("unauthorized"))
      end)

      assert {:error, {:http_status, 404}} = fetch_response(route_id: "40_N23:S07 a/b")

      assert_received {:request, "/api/where/stops-for-route/40_N23%3AS07%20a%2Fb.json",
                       %{"key" => @api_key, "includePolylines" => "true"}}
    end
  end

  describe "fetch_response/2 value errors" do
    for {name, fixture_name, status, error} <- [
          {"a 500 response", "server_error", 500, {:http_status, 500}},
          {"a 401 response", "unauthorized", 401, {:http_status, 401}},
          {"a route the server does not know", "unauthorized", 404, {:http_status, 404}},
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
          {"the payload violates the schema", "stops_for_route_schema_violation",
           ~r/schema mismatch/},
          {"a stop identifier repeats", "stops_for_route_duplicate_stop", ~r/repeats/}
        ] do
      test "raises when #{name}" do
        stub_fixture(unquote(fixture_name))

        assert_raise AssertionError, unquote(Macro.escape(message)), fn -> fetch_response() end
      end
    end

    test "raises when the response is for another route than the one asked for" do
      stub_fixture("stops_for_route")

      assert_raise AssertionError, ~r/another than the one asked for/, fn ->
        fetch_response(route_id: "1_100337")
      end
    end

    test "raises for an empty route identifier" do
      assert_raise AssertionError, ~r/route identifier/, fn -> fetch_response(route_id: "") end
    end

    test "raises when the caller supplies query parameters" do
      assert_raise AssertionError, ~r/params/, fn ->
        fetch_response(params: [includePolylines: "false"])
      end
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
        fn -> stub_body(String.replace(fixture("stops_for_route"), "Harbor", @api_key)) end,
        fn -> stub_fixture("unauthorized", 401) end,
        fn -> stub_body(echoing_body) end,
        fn -> stub_body("not json #{@api_key}") end,
        fn -> stub_fixture("stops_for_route_schema_violation") end
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

  describe "parse/2 optional data" do
    test "returns no polylines for a route that has none" do
      data =
        data()
        |> put_in(["entry", "polylines"], [])
        |> update_in(["entry", "stopGroupings", Access.at(0), "stopGroups"], fn groups ->
          Enum.map(groups, &Map.put(&1, "polylines", []))
        end)

      assert {:ok, %{polylines: [], stop_groupings: [%{stop_groups: groups}]}} = parse(data)
      assert Enum.map(groups, & &1.polylines) == [[], []]
    end

    test "returns no groupings for a route that has none" do
      assert {:ok, %{stop_groupings: [], stop_ids: ["1_1889", "1_99997"]}} =
               parse(put_in(data(), ["entry", "stopGroupings"], []))
    end

    test "returns no name for a group whose name is empty" do
      data = put_in(data(), group_path() ++ ["name", "name"], "")

      assert {:ok, %{stop_groupings: [%{stop_groups: [%{name: nil}, _other]}]}} = parse(data)
    end

    test "returns no names for a group whose one name is null" do
      data =
        data()
        |> put_in(group_path() ++ ["name", "name"], "")
        |> put_in(group_path() ++ ["name", "names"], [nil])

      assert {:ok, %{stop_groupings: [%{stop_groups: [group, _other]}]}} = parse(data)
      assert %{name: nil, names: []} = group
    end

    test "returns an empty path for a route with no stops and no groups" do
      data =
        data()
        |> put_in(["entry", "stopIds"], [])
        |> put_in(["entry", "polylines"], [])
        |> put_in(["entry", "stopGroupings", Access.at(0), "stopGroups"], [])
        |> put_in(["references", "stops"], [])

      assert parse(data) ==
               {:ok,
                %{
                  route_id: "1_100336",
                  stop_ids: [],
                  polylines: [],
                  stop_groupings: [%{type: "direction", ordered: true, stop_groups: []}],
                  stops: []
                }}
    end

    test "returns the levels a polyline supplies" do
      data = put_in(data(), ["entry", "polylines", Access.at(0), "levels"], "BBB")

      assert {:ok, %{polylines: [%{levels: "BBB"}]}} = parse(data)
    end

    for {name, field, key} <- [
          {"code", "code", :code},
          {"direction", "direction", :direction},
          {"parent", "parent", :parent}
        ] do
      test "returns no #{name} for a stop whose #{name} is empty" do
        data = put_in(data(), ["references", "stops", Access.at(0), unquote(field)], "")

        assert {:ok, %{stops: [stop, _other]}} = parse(data)
        assert Map.fetch!(stop, unquote(key)) == nil
      end
    end

    test "returns the direction and the parent a stop supplies" do
      data =
        data()
        |> put_in(["references", "stops", Access.at(0), "direction"], "NW")
        |> put_in(["references", "stops", Access.at(0), "parent"], "1_station")

      assert {:ok, %{stops: [%{direction: "NW", parent: "1_station"}, _other]}} = parse(data)
    end

    test "leaves out a referenced stop the route does not list" do
      extra = %{(data()["references"]["stops"] |> hd()) | "id" => "1_other"}
      data = update_in(data(), ["references", "stops"], &(&1 ++ [extra]))

      assert {:ok, %{stops: stops}} = parse(data)
      assert Enum.map(stops, & &1.id) == ["1_1889", "1_99997"]
    end

    test "accepts a group with sub-groups and leaves them out" do
      data = put_in(data(), group_path() ++ ["subGroups"], [%{"id" => "a"}])

      assert {:ok, %{stop_groupings: [%{stop_groups: [group, _other]}]}} = parse(data)
      refute is_map_key(group, :sub_groups)
    end
  end

  describe "parse/2 contract violations" do
    test "returns the path of a schema mismatch" do
      data =
        "stops_for_route_schema_violation" |> fixture() |> JSON.decode!() |> Map.fetch!("data")

      assert parse(data) ==
               {:error,
                {:schema_mismatch,
                 %{path: ["entry", "polylines", 0, "points"], expected: :required}}}
    end

    test "returns a schema mismatch for data that is not a map" do
      assert {:error, {:schema_mismatch, %{path: []}}} = parse("text")
    end

    test "returns a schema mismatch for a point count that is not an integer" do
      data = put_in(data(), ["entry", "polylines", Access.at(0), "length"], 2.5)

      assert {:error, {:schema_mismatch, %{path: ["entry", "polylines", 0, "length"]}}} =
               parse(data)
    end

    test "returns the route of a response for another route" do
      assert RoutePaths.parse(data(), "1_100337") == {:error, {:route_mismatch, "1_100336"}}
    end

    test "returns the identifier of a repeated stop" do
      data = update_in(data(), ["entry", "stopIds"], &(&1 ++ ["1_1889"]))

      assert parse(data) == {:error, {:duplicate_stop, "1_1889"}}
    end

    test "returns a group's stop that the route does not list" do
      data = update_in(data(), group_path() ++ ["stopIds"], &(&1 ++ ["1_other"]))

      assert parse(data) == {:error, {:unlisted_stop, "1_other"}}
    end

    test "returns a stop of the route that has no reference" do
      data = update_in(data(), ["references", "stops"], &Enum.take(&1, 1))

      assert parse(data) == {:error, {:unreferenced_stop, "1_99997"}}
    end

    for {name, change} <- [
          {"a character outside the encoding", quote(do: &Map.put(&1, "points", "mbpaH phuiV"))},
          {"no text", quote(do: &Map.put(&1, "points", ""))},
          {"no points", quote(do: &Map.put(&1, "length", 0))}
        ] do
      test "returns invalid_polyline for a route polyline with #{name}" do
        data = update_in(data(), ["entry", "polylines", Access.at(0)], unquote(change))

        assert {:error, {:invalid_polyline, %{points: _points, point_count: _count}}} =
                 parse(data)
      end
    end

    test "returns invalid_polyline for a malformed polyline of a group" do
      data = put_in(data(), group_path() ++ ["polylines", Access.at(0), "points"], "a b")

      assert parse(data) ==
               {:error, {:invalid_polyline, %{points: "a b", point_count: 3, levels: nil}}}
    end

    test "returns the stop count when it exceeds the bound" do
      [stop | _stops] = data()["references"]["stops"]
      stop_ids = for index <- 1..1_001, do: "1_#{index}"

      data =
        data()
        |> put_in(["entry", "stopIds"], stop_ids)
        |> put_in(["references", "stops"], Enum.map(stop_ids, &Map.put(stop, "id", &1)))

      assert parse(data) == {:error, {:stop_count_exceeded, 1_001}}
    end

    test "returns the polyline count when the route's and the groups' exceed the bound" do
      [polyline] = data()["entry"]["polylines"]
      data = put_in(data(), ["entry", "polylines"], List.duplicate(polyline, 999))

      assert parse(data) == {:error, {:polyline_count_exceeded, 1_001}}
    end

    test "returns the grouping count when it exceeds the bound" do
      [grouping] = data()["entry"]["stopGroupings"]
      data = put_in(data(), ["entry", "stopGroupings"], List.duplicate(grouping, 9))

      assert parse(data) == {:error, {:stop_grouping_count_exceeded, 9}}
    end

    test "returns the group count when it exceeds the bound" do
      [group | _groups] = get_in(data(), ["entry", "stopGroupings", Access.at(0), "stopGroups"])

      data =
        put_in(
          data(),
          ["entry", "stopGroupings", Access.at(0), "stopGroups"],
          List.duplicate(group, 17)
        )

      assert parse(data) == {:error, {:stop_group_count_exceeded, 17}}
    end
  end
end
