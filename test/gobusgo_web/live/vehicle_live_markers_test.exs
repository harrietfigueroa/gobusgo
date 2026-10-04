defmodule GobusgoWeb.VehicleLiveMarkersTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's vehicle
  # view, filled with the record values VehicleBatch.Records builds. Both are
  # global state, hence the non-async case. The browser draws the markers,
  # so these tests observe what the page hands it: the events that carry
  # each agency's markers, and the legend and the counts beside the map.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.VehicleMarkers

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @event "vehicle-markers:agency"
  @push_wait_ms 50
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => [
      %{"agencyId" => "1", "archive" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}
    ]
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
    restart_view()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_view()
    end)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, VehicleView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, VehicleView)
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  defp vehicle(id, fields \\ %{}) do
    Map.merge(
      %{
        id: id,
        active_trip_id: nil,
        position: %{lat: 47.66, lon: -122.34},
        orientation: nil,
        last_known_location: nil,
        last_known_orientation: nil,
        last_update_time_ms: nil,
        last_location_update_time_ms: DateTime.to_unix(@fetched_at, :millisecond),
        predicted: true
      },
      fields
    )
  end

  # Publishes a fetch of `agency_id`; `sequence` orders the fetches of a
  # test, as the request identifier and as seconds after the first fetch.
  defp apply_fetch(vehicles, %{agency_id: agency_id, sequence: sequence}) do
    %{vehicles: records, manifest: manifest} =
      Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=#{agency_id}/file.json",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        vehicles: vehicles
      })

    :ok = VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  defp open_page do
    {:ok, view, _html} = live(build_conn(), "/vehicles")
    view
  end

  defp ready(view),
    do: view |> element("#vehicle-markers") |> render_hook("vehicle-markers:ready")

  defp text(view, selector), do: view |> element(selector) |> render()

  describe "the map's ready event" do
    test "is answered with the markers of every agency" do
      apply_fetch([vehicle("1_a")], %{agency_id: "1", sequence: 1})
      apply_fetch([vehicle("40_x")], %{agency_id: "40", sequence: 2})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_x"}]})
    end

    test "is answered with a marker's position, status, and texts" do
      apply_fetch([vehicle("1_a", %{last_location_update_time_ms: 0, predicted: false})], %{
        agency_id: "1",
        sequence: 0
      })

      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{
        markers: [
          %{
            vehicle_id: "1_a",
            lat: 47.66,
            lon: -122.34,
            status: :scheduled,
            location_age: "No location reported",
            real_time: "No"
          }
        ]
      })
    end

    test "is answered with nothing before any fetch is complete" do
      view = open_page()

      ready(view)

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end

    test "leaves out a vehicle with no position" do
      apply_fetch([vehicle("1_a"), vehicle("1_b", %{position: nil})], %{
        agency_id: "1",
        sequence: 1
      })

      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{vehicle_id: "1_a"}]})
    end
  end

  describe "a fetch that completes while the page is open" do
    setup do
      apply_fetch([vehicle("1_a"), vehicle("1_b")], %{agency_id: "1", sequence: 1})
      apply_fetch([vehicle("40_x")], %{agency_id: "40", sequence: 1})
      %{view: open_page()}
    end

    test "sends the new position of a vehicle that moved", %{view: view} do
      moved = vehicle("1_a", %{position: %{lat: 47.7, lon: -122.3}})
      apply_fetch([moved, vehicle("1_b")], %{agency_id: "1", sequence: 2})

      assert_push_event(view, @event, %{
        agency_id: "1",
        markers: [%{vehicle_id: "1_a", lat: 47.7, lon: -122.3}, %{vehicle_id: "1_b"}]
      })
    end

    test "sends the agency's markers without a vehicle that left the fetch", %{view: view} do
      apply_fetch([vehicle("1_b")], %{agency_id: "1", sequence: 2})

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{vehicle_id: "1_b"}]})
    end

    test "sends no markers for an agency whose fetch holds no vehicles", %{view: view} do
      apply_fetch([], %{agency_id: "1", sequence: 2})

      assert_push_event(view, @event, %{agency_id: "1", markers: []})
    end

    test "sends nothing for an agency whose fetch stayed the same", %{view: view} do
      apply_fetch([vehicle("1_b")], %{agency_id: "1", sequence: 2})

      assert_push_event(view, @event, %{agency_id: "1"})
      refute_push_event(view, @event, %{agency_id: "40"}, @push_wait_ms)
    end

    test "sends the status a report has at the new fetch time", %{view: view} do
      apply_fetch([vehicle("1_a")], %{agency_id: "1", sequence: 121})

      assert_push_event(view, @event, %{
        agency_id: "1",
        markers: [%{status: :stale, location_age: "2 min 1 s ago"}]
      })
    end

    test "counts the vehicles on the map anew", %{view: view} do
      apply_fetch([vehicle("1_b")], %{agency_id: "1", sequence: 2})

      assert_push_event(view, @event, %{agency_id: "1"})
      assert text(view, "#marker-count") =~ "2 vehicles on the map."
    end
  end

  describe "beside the map" do
    test "states that a marker stands at the estimated position" do
      view = open_page()

      assert text(view, "#marker-position-note") =~
               "Each marker stands at the source&#39;s estimated position"
    end

    test "lists every status with its label and description" do
      view = open_page()

      for %{status: status, label: label, description: description} <- VehicleMarkers.statuses() do
        item = text(view, "#marker-status-#{status}")
        assert item =~ label
        assert item =~ description
      end
    end

    test "hands the browser the definition of every status" do
      view = open_page()

      [statuses] =
        view
        |> text("#vehicle-markers")
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#vehicle-markers")
        |> LazyHTML.attribute("data-statuses")

      assert Enum.map(JSON.decode!(statuses), & &1["status"]) ==
               ~w(reported stale scheduled unknown)
    end

    test "says that no vehicles are on the map before any fetch is complete" do
      view = open_page()

      assert text(view, "#marker-count") =~ "No vehicles on the map."
      assert text(view, "#marker-position-missing") =~ "Every vehicle has a position."
    end

    test "counts the vehicles on the map and the ones with no position" do
      apply_fetch(
        [vehicle("1_a"), vehicle("1_b", %{position: nil}), vehicle("1_c", %{position: nil})],
        %{agency_id: "1", sequence: 1}
      )

      apply_fetch([vehicle("40_x")], %{agency_id: "40", sequence: 1})
      view = open_page()

      assert text(view, "#marker-count") =~ "2 vehicles on the map."

      assert text(view, "#marker-position-missing") =~
               "2 vehicles have no position and are not on the map."
    end
  end

  describe "without a basemap" do
    test "shows no legend and no counts", %{tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "manifest.json"))
      apply_fetch([vehicle("1_a")], %{agency_id: "1", sequence: 1})
      view = open_page()

      refute has_element?(view, "#vehicle-markers")
    end
  end
end
