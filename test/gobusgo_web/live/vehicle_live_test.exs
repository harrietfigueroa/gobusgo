defmodule GobusgoWeb.VehicleLiveTest do
  # Mounts the page with Phoenix.LiveViewTest and fills the application's
  # vehicle view with the record values VehicleBatch.Records builds: a
  # vehicle that reports its location, one that never has, and one that
  # supplies nothing but its identifier. Each test restarts that view, which
  # is global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  setup do
    restart_view()
    on_exit(&restart_view/0)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, VehicleView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, VehicleView)
  end

  defp bare(id) do
    %{
      id: id,
      active_trip_id: nil,
      position: nil,
      orientation: nil,
      last_known_location: nil,
      last_known_orientation: nil,
      last_update_time_ms: nil,
      last_location_update_time_ms: nil,
      predicted: nil
    }
  end

  defp reporting(id) do
    %{
      bare(id)
      | active_trip_id: "1_15436438",
        position: %{lat: 47.66, lon: -122.34},
        last_known_location: %{lat: 47.65, lon: -122.33},
        last_location_update_time_ms: DateTime.to_unix(~U[2026-10-02 03:14:30Z], :millisecond),
        predicted: true
    }
  end

  defp scheduled(id) do
    %{
      bare(id)
      | position: %{lat: 47.61, lon: -122.31},
        last_location_update_time_ms: 0,
        predicted: false
    }
  end

  defp apply_fetch(vehicles, overrides \\ %{}) do
    %{vehicles: records, manifest: manifest} =
      Records.build(
        Map.merge(
          %{
            agency_id: "1",
            destination: "raw/oba/vehicles-for-agency/agency=1/dt=2026-10-02/file.json",
            fetched_at: ~U[2026-10-02 03:15:00Z],
            data_sha256: String.duplicate("ab", 32),
            request_id: @request_id,
            vehicles: vehicles
          },
          overrides
        )
      )

    :ok = VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody tr")
    |> LazyHTML.attribute("id")
  end

  defp cell(view, row_id, column) do
    view |> element("##{row_id} [data-column=#{column}]") |> render()
  end

  describe "GET /vehicles without vehicle data" do
    test "says that no vehicle data is available yet" do
      {:ok, view, html} = live(build_conn(), "/vehicles")

      assert html =~ "No vehicle data yet."
      refute has_element?(view, "table")
    end
  end

  describe "GET /vehicles with vehicle data" do
    test "lists every vehicle of the current fetches, by agency and then by vehicle" do
      apply_fetch([bare("40_x")], %{
        agency_id: "40",
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000040"
      })

      apply_fetch([bare("1_b"), bare("1_a")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert row_ids(view) == ["vehicle-1-1_a", "vehicle-1-1_b", "vehicle-40-40_x"]
    end

    test "shows the identity and the trip of a vehicle" do
      apply_fetch([reporting("1_4207")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert cell(view, "vehicle-1-1_4207", "vehicle") =~ "1_4207"
      assert cell(view, "vehicle-1-1_4207", "agency") =~ ">1<"
      assert cell(view, "vehicle-1-1_4207", "trip") =~ "1_15436438"
    end

    test "shows the estimated position apart from the last reported location" do
      apply_fetch([reporting("1_4207")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert cell(view, "vehicle-1-1_4207", "estimated-position") =~ "47.66, -122.34"
      assert cell(view, "vehicle-1-1_4207", "reported-location") =~ "47.65, -122.33"
    end

    test "names the position column an estimate and the location column a report" do
      apply_fetch([reporting("1_4207")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")
      head = view |> element("thead") |> render()

      assert head =~ "Estimated position"
      assert head =~ "Last reported location"
      refute head =~ "GPS"
    end

    test "shows when the vehicle reported its location, apart from the fetch time" do
      apply_fetch([reporting("1_4207")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert cell(view, "vehicle-1-1_4207", "location-reported-at") =~ "2026-10-02T03:14:30.000Z"
      assert cell(view, "vehicle-1-1_4207", "fetched-at") =~ "2026-10-02T03:15:00Z"
    end

    test "shows whether the source has real-time data for the vehicle" do
      apply_fetch([reporting("1_a"), scheduled("1_b")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert cell(view, "vehicle-1-1_a", "real-time") =~ "Yes"
      assert cell(view, "vehicle-1-1_b", "real-time") =~ "No"
    end

    test "says that a vehicle with a zero update time has reported no location" do
      apply_fetch([scheduled("1_b")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert cell(view, "vehicle-1-1_b", "location-reported-at") =~ "No location reported"
      assert cell(view, "vehicle-1-1_b", "estimated-position") =~ "47.61, -122.31"
    end

    test "says that a field the source did not supply was not supplied" do
      apply_fetch([bare("1_c")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      for column <- [
            "trip",
            "estimated-position",
            "reported-location",
            "location-reported-at",
            "real-time"
          ] do
        assert cell(view, "vehicle-1-1_c", column) =~ "Not supplied"
      end
    end

    test "shows the fetch each agency's vehicles come from" do
      apply_fetch([bare("1_a"), bare("1_b")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")
      fetch = view |> element("#fetch-1") |> render()

      assert fetch =~ "2 vehicles"
      assert fetch =~ "2026-10-02T03:15:00Z"
      assert fetch =~ @request_id
    end

    test "counts a single vehicle in the singular" do
      apply_fetch([bare("1_a")])

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element("#fetch-1") |> render() =~ "1 vehicle,"
    end

    test "answers the first request with the vehicles, before the socket connects" do
      apply_fetch([bare("1_4207")])

      assert build_conn() |> get("/vehicles") |> html_response(200) =~ "1_4207"
    end
  end

  describe "an open page" do
    test "shows a fetch that completes after the page was opened" do
      {:ok, view, html} = live(build_conn(), "/vehicles")
      assert html =~ "No vehicle data yet."

      apply_fetch([bare("1_a")])

      assert row_ids(view) == ["vehicle-1-1_a"]
    end

    test "moves a vehicle to the position a later fetch gives it" do
      apply_fetch([reporting("1_a")])
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      apply_fetch([%{reporting("1_a") | position: %{lat: 47.7, lon: -122.4}}], %{
        fetched_at: ~U[2026-10-02 03:16:00Z],
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
      })

      assert cell(view, "vehicle-1-1_a", "estimated-position") =~ "47.7, -122.4"
      assert cell(view, "vehicle-1-1_a", "fetched-at") =~ "2026-10-02T03:16:00Z"
    end

    test "drops a vehicle a later fetch of its agency no longer names" do
      apply_fetch([bare("1_a"), bare("1_b")])
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      apply_fetch([bare("1_a")], %{
        fetched_at: ~U[2026-10-02 03:16:00Z],
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
      })

      assert row_ids(view) == ["vehicle-1-1_a"]
    end
  end
end
