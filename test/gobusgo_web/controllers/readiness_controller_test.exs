defmodule GobusgoWeb.ReadinessControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest. The agency
  # view is filled the way the application fills it, from a stored response
  # that is processed, and the two route views are seeded with the records
  # their processors build. Each test restarts the application's views, which
  # are global state, hence the non-async case.
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

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @fixture_agency_ids ["1", "40", "77"]
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @problem_content_type "application/problem+json; charset=utf-8"

  setup do
    restart_views()
    on_exit(&restart_views/0)
  end

  defp restart_views do
    for view <- [AgencyView, RouteView, RoutePathView] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
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
               "detail" => "No agency fetch is available yet."
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
      process_agencies(tmp_dir)
      seed_routes(%{"40" => ["40_a"]})
      RouteViewSeeds.route_path(RoutePathView, %{route_id: "40_a", fetched_at: @fetched_at})

      conn = get(build_conn(), "/ready")

      assert json_response(conn, 200) == %{"status" => "ready"}
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "is not logged" do
      assert GobusgoWeb.Endpoint.log_level(%Plug.Conn{request_path: "/ready"}) == false
    end
  end
end
