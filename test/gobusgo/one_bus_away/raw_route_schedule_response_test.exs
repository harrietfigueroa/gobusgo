defmodule Gobusgo.OneBusAway.RawRouteScheduleResponseTest do
  # Verifies the stored form of a route schedule response as a pure function
  # of the response and the request identifier. Destinations and `meta` are
  # written out by hand, and parse/1 is driven with content build/1 produced
  # from the fixture cut from a live response, then altered one rule at a
  # time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteSchedules

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @route_id "19_41"

  defp envelope do
    @fixture_directory |> Path.join("schedule_for_route.json") |> File.read!() |> JSON.decode!()
  end

  defp schedule do
    {:ok, schedule} = RouteSchedules.parse(envelope()["data"], @route_id)
    schedule
  end

  defp response(overrides) do
    Map.merge(
      %{
        route_id: @route_id,
        service_date: ~D[2026-11-07],
        schedule: schedule(),
        envelope: envelope(),
        fetched_at: ~U[2026-11-06 23:15:00.987654Z],
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      },
      overrides
    )
  end

  defp build(overrides \\ %{}) do
    RawRouteScheduleResponse.build(%{response: response(overrides), request_id: @request_id})
  end

  defp parse(stored, changes \\ %{}) do
    RawRouteScheduleResponse.parse(Map.merge(Map.take(stored, [:destination, :content]), changes))
  end

  defp alter(content, path, value) do
    content |> JSON.decode!() |> put_in(path, value) |> Gobusgo.CanonicalJson.encode()
  end

  describe "build/1 destination" do
    test "is the fetch date, the route, the service date, fetch time, request, and hash prefix" do
      stored = build()

      assert stored.destination ==
               "raw/oba/schedule-for-route/dt=2026-11-06/route=19_41/service-date=2026-11-07/" <>
                 "20261106T231500Z_#{@request_id}_#{binary_part(stored.data_sha256, 0, 12)}.json.gz"

      assert {:ok, _segments} = Destination.validate(stored.destination)
    end

    test "escapes a route identifier as the other datasets do" do
      assert build(%{route_id: "a/b"}).destination =~ "/route=a.2Fb/service-date=2026-11-07/"
    end
  end

  describe "service_date/1" do
    test "reads the service date a destination names" do
      assert RawRouteScheduleResponse.service_date(build().destination) == {:ok, ~D[2026-11-07]}
    end

    test "returns :error for a destination that names none" do
      assert RawRouteScheduleResponse.service_date("raw/oba/schedule-for-route/x.json.gz") ==
               :error
    end
  end

  describe "build/1 content" do
    test "holds the route and the service date beside the shared meta fields" do
      meta = JSON.decode!(build().content)["meta"]

      assert %{"routeId" => "19_41", "serviceDate" => "2026-11-07"} = meta
    end

    test "keeps the envelope unchanged under body" do
      assert JSON.decode!(build().content)["body"] == envelope()
    end
  end

  describe "build/1 assertions" do
    test "raises for an empty route identifier" do
      assert_raise AssertionError, fn -> build(%{route_id: ""}) end
    end

    test "raises for a response without service, which is never stored" do
      assert_raise AssertionError, fn -> build(%{schedule: :no_service}) end
    end
  end

  describe "parse/1" do
    test "returns the fetch build/1 stored, its schedule included" do
      stored = build()

      assert parse(stored) ==
               {:ok,
                %{
                  route_id: @route_id,
                  service_date: ~D[2026-11-07],
                  destination: stored.destination,
                  fetched_at: ~U[2026-11-06 23:15:00Z],
                  data_sha256: stored.data_sha256,
                  request_id: @request_id,
                  schedule: schedule()
                }}
    end

    test "rejects content that is not JSON" do
      assert parse(build(), %{content: "{"}) == {:error, :invalid_json}
    end

    test "rejects data that does not hash to the recorded hash" do
      stored = build()
      content = alter(stored.content, ["body", "data", "limitExceeded"], true)

      assert parse(stored, %{content: content}) == {:error, :hash_mismatch}
    end

    for service_date <- ["", "2026-13-01", 20_261_107] do
      test "rejects the service date #{inspect(service_date)} in meta" do
        stored = build()
        content = alter(stored.content, ["meta", "serviceDate"], unquote(service_date))

        assert parse(stored, %{content: content}) == {:error, :schema_mismatch}
      end
    end

    test "rejects content stored under another service date's destination" do
      stored = build()
      content = alter(stored.content, ["meta", "serviceDate"], "2026-11-08")

      assert parse(stored, %{content: content}) == {:error, :destination_mismatch}
    end

    test "rejects data that is not the route's schedule" do
      other_route = put_in(envelope(), ["data", "entry", "routeId"], "19_42")

      assert parse(build(%{envelope: other_route})) == {:error, :schema_mismatch}
    end
  end
end
