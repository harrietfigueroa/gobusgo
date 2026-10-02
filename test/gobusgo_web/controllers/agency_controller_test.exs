defmodule GobusgoWeb.AgencyControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest. The view is
  # filled the way the application fills it: a stored response is written
  # through the writer and processed, and the configured publisher hands the
  # records to the view. Each test restarts the application's view, which is
  # global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @problem_content_type "application/problem+json; charset=utf-8"

  setup do
    restart_view()
    on_exit(&restart_view/0)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, AgencyView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, AgencyView)
  end

  defp store(tmp_dir) do
    response = %{
      agencies: [],
      envelope: @fixture_path |> File.read!() |> JSON.decode!(),
      fetched_at: ~U[2026-10-02 03:15:00Z],
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    stored = RawAgencyResponse.build(%{response: response, request_id: @request_id})
    :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: tmp_dir)
    stored.destination
  end

  defp process(tmp_dir) do
    {:ok, _result} = AgencyBatch.process(store(tmp_dir), read_options: [base_dir: tmp_dir])
  end

  describe "GET /api/agencies" do
    test "answers 200 with every agency of the processed fetch and its freshness", %{
      tmp_dir: tmp_dir
    } do
      process(tmp_dir)

      conn = get(build_conn(), "/api/agencies")

      assert json_response(conn, 200) == %{
               "data" => [
                 %{
                   "id" => "1",
                   "name" => "Metro Transit",
                   "url" => "https://metro.example.test",
                   "timezone" => "America/Los_Angeles",
                   "coverage" => %{
                     "lat" => 47.53009,
                     "lon" => -122.1462285,
                     "latSpan" => 0.681946,
                     "lonSpan" => 0.720787
                   }
                 },
                 %{
                   "id" => "40",
                   "name" => "Regional Transit",
                   "url" => "https://regional.example.test",
                   "timezone" => "America/Los_Angeles",
                   "coverage" => %{
                     "lat" => 47.6,
                     "lon" => -122.3,
                     "latSpan" => 0.5,
                     "lonSpan" => 0.4
                   }
                 }
               ],
               "meta" => %{
                 "count" => 2,
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "requestId" => @request_id
               }
             }
    end

    test "answers 503 with problem details and Retry-After before a fetch is complete" do
      conn = get(build_conn(), "/api/agencies")

      assert conn.status == 503
      assert get_resp_header(conn, "content-type") == [@problem_content_type]
      assert get_resp_header(conn, "retry-after") == ["5"]

      assert JSON.decode!(conn.resp_body) == %{
               "type" => "about:blank",
               "title" => "Service Unavailable",
               "status" => 503,
               "detail" => "No agency fetch is available yet."
             }
    end
  end

  describe "GET /api/agencies/:id" do
    test "answers 200 with the agency and the freshness of its fetch", %{tmp_dir: tmp_dir} do
      process(tmp_dir)

      conn = get(build_conn(), "/api/agencies/40")

      assert %{
               "data" => %{"id" => "40", "name" => "Regional Transit"},
               "meta" => %{"fetchedAt" => "2026-10-02T03:15:00Z", "requestId" => @request_id}
             } = json_response(conn, 200)

      assert json_response(conn, 200)["meta"] |> Map.keys() == ["fetchedAt", "requestId"]
    end

    test "answers 404 with problem details for an agency the fetch does not hold", %{
      tmp_dir: tmp_dir
    } do
      process(tmp_dir)

      conn = get(build_conn(), "/api/agencies/77")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == [@problem_content_type]

      assert JSON.decode!(conn.resp_body) == %{
               "type" => "about:blank",
               "title" => "Not Found",
               "status" => 404,
               "detail" => "No agency has the identifier 77."
             }
    end

    test "answers 503 with problem details before a fetch is complete" do
      conn = get(build_conn(), "/api/agencies/1")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
    end
  end
end
