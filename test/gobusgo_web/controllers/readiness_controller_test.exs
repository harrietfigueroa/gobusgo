defmodule GobusgoWeb.ReadinessControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest. The agency
  # view is filled the way the application fills it, from a stored response
  # that is processed, and the two route views are seeded with the records
  # their processors build. The tile archive process is given an archive by
  # `record/2`, built a chosen time before the request. Each test restarts the
  # application's views and the tile archive process, which are global state,
  # hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RoutePathView
  alias Gobusgo.OneBusAway.RouteView
  alias Gobusgo.Test.RouteViewSeeds
  alias Gobusgo.Writer
  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.RouteStopTiles.Build

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @fixture_agency_ids ["1", "40", "77"]
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @problem_content_type "application/problem+json; charset=utf-8"
  @content_sha256 :crypto.hash(:sha256, "features")
  @current_age_seconds 60
  # The request reads the clock after the test does, so the age it reports is
  # at most this much more than the one the test recorded.
  @age_slack_seconds 5

  setup do
    restart_views()
    on_exit(&restart_views/0)
  end

  defp restart_views do
    for view <- [AgencyView, RouteView, RoutePathView, RouteStopTiles] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp record_tiles(age_seconds) do
    built_at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    :ok =
      RouteStopTiles.record(RouteStopTiles, %{
        destination:
          RouteStopTiles.destination(%{built_at: built_at, content_sha256: @content_sha256}),
        content_sha256: @content_sha256,
        built_at: built_at
      })
  end

  defp fill_views(tmp_dir) do
    process_agencies(tmp_dir)
    seed_routes(%{"40" => ["40_a"]})
    RouteViewSeeds.route_path(RoutePathView, %{route_id: "40_a", fetched_at: @fetched_at})
  end

  defp assert_age(body, age_seconds) do
    assert body["tilesAgeSeconds"] >= age_seconds
    assert body["tilesAgeSeconds"] <= age_seconds + @age_slack_seconds
  end

  defp process_agencies(tmp_dir) do
    response = %{
      agencies: [],
      envelope: @fixture_path |> File.read!() |> JSON.decode!(),
      fetched_at: @fetched_at,
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    stored = RawAgencyResponse.build(%{response: response, request_id: @request_id})
    :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: tmp_dir)

    {:ok, _result} =
      AgencyBatch.process(stored.destination, read_options: [base_dir: tmp_dir])
  end

  defp seed_routes(route_ids_by_agency) do
    for agency_id <- @fixture_agency_ids do
      RouteViewSeeds.routes(RouteView, %{
        agency_id: agency_id,
        route_ids: Map.get(route_ids_by_agency, agency_id, []),
        fetched_at: @fetched_at
      })
    end
  end

  describe "GET /ready" do
    test "answers 503 problem details while the agency view has no fetch" do
      conn = get(build_conn(), "/ready")

      assert json_response(conn, 503) == %{
               "type" => "about:blank",
               "title" => "Service Unavailable",
               "status" => 503,
               "detail" => "No agency fetch is available yet.",
               "tiles" => "none"
             }

      assert get_resp_header(conn, "content-type") == [@problem_content_type]
      assert get_resp_header(conn, "retry-after") == ["5"]
    end

    test "answers 503 with the count of route items that have no attempt", %{tmp_dir: tmp_dir} do
      process_agencies(tmp_dir)
      seed_routes(%{"40" => ["40_a", "40_b"]})
      RouteViewSeeds.route_path(RoutePathView, %{route_id: "40_a", fetched_at: @fetched_at})

      conn = get(build_conn(), "/ready")

      assert json_response(conn, 503)["detail"] ==
               "1 route item has not been fetched yet."

      assert get_resp_header(conn, "retry-after") == ["5"]
    end

    test "answers 200 once every agency and every listed route has a fetch", %{
      tmp_dir: tmp_dir
    } do
      fill_views(tmp_dir)

      conn = get(build_conn(), "/ready")

      assert %{"status" => "ready"} = json_response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "reports no tile archive while the process holds none", %{tmp_dir: tmp_dir} do
      fill_views(tmp_dir)

      conn = get(build_conn(), "/ready")

      assert json_response(conn, 200) == %{"status" => "ready", "tiles" => "none"}
    end

    for {tiles, age_seconds} <- [
          {"current", quote(do: @current_age_seconds)},
          {"stale", quote(do: Build.renewal_age_seconds() + @current_age_seconds)}
        ] do
      test "reports a #{tiles} tile archive with its age and stays ready", %{tmp_dir: tmp_dir} do
        fill_views(tmp_dir)
        age_seconds = unquote(age_seconds)
        record_tiles(age_seconds)

        body = build_conn() |> get("/ready") |> json_response(200)

        assert %{"status" => "ready", "tiles" => unquote(tiles)} = body
        assert_age(body, age_seconds)
      end
    end

    test "reports a tile archive whose name holds no build time as stale with no age", %{
      tmp_dir: tmp_dir
    } do
      fill_views(tmp_dir)

      :ok =
        RouteStopTiles.record(RouteStopTiles, %{
          destination: RouteStopTiles.prefix() <> "/dt=2026-10-05/other.pmtiles",
          content_sha256: @content_sha256,
          built_at: DateTime.utc_now()
        })

      conn = get(build_conn(), "/ready")

      assert json_response(conn, 200) == %{"status" => "ready", "tiles" => "stale"}
    end

    test "reports the tile archive while the views are filling, and stays 503" do
      stale_age_seconds = Build.renewal_age_seconds() + @current_age_seconds
      record_tiles(stale_age_seconds)

      conn = get(build_conn(), "/ready")
      body = json_response(conn, 503)

      assert %{"status" => 503, "detail" => "No agency fetch is available yet."} = body
      assert body["tiles"] == "stale"
      assert_age(body, stale_age_seconds)
      assert get_resp_header(conn, "retry-after") == ["5"]
    end

    test "is not logged" do
      assert GobusgoWeb.Endpoint.log_level(%Plug.Conn{request_path: "/ready"}) == false
    end
  end
end
