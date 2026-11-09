defmodule GobusgoWeb.VehicleLiveFavoriteStopTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap
  # directory the test names and the application's stop view, both global
  # state, hence the non-async case. The browser keeps the favorite and
  # writes the panel, so these tests observe the element the panel's hook
  # mounts on, where the page renders it and that the page leaves its
  # content to the hook, and what the page answers the hook's request for a
  # favorite's position with.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView
  alias GobusgoWeb.VehicleLive.OpenStops

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @panel "#favorite-stop"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)
    :ok
  end

  defp write_manifest(tmp_dir),
    do: File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))

  defp panel(view) do
    view |> element(@panel) |> render() |> LazyHTML.from_fragment()
  end

  defp restart_stop_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, StopView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, StopView)
  end

  # Has the stop view hold the stop 1_431 at 47.6101, -122.3378.
  defp apply_stop do
    stop = %{
      id: "1_431",
      name: "3rd Ave & Pike St",
      lat: 47.6101,
      lon: -122.3378,
      code: "431",
      direction: "N",
      location_type: 0,
      parent: nil,
      wheelchair_boarding: "UNKNOWN",
      route_ids: ["1_100210"]
    }

    record =
      StopRecords.build(%{
        route_id: "1_100210",
        destination: "raw/oba/stops-for-route/dt=2026-11-08/route=1_100210/file.json.gz",
        fetched_at: ~U[2026-11-08 17:00:00Z],
        data_sha256: String.duplicate("ab", 32),
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000000",
        route_path: %{
          route_id: "1_100210",
          stop_ids: ["1_431"],
          polylines: [],
          stop_groupings: [],
          stops: [stop],
          parent_stops: []
        }
      })

    :ok = StopView.apply_records(StopView, [record.value])
  end

  defp request_position(view, params),
    do: view |> element(@panel) |> render_hook("stop:position", params)

  describe "GET /vehicles with a basemap" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
    end

    test "renders the favorite stops' panel empty, for its hook to fill" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      panel = panel(view)

      assert LazyHTML.attribute(panel, "phx-hook") == ["FavoriteStop"]
      assert panel |> LazyHTML.text() |> String.trim() == ""
    end

    test "leaves the panel's content to its hook across patches" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> panel() |> LazyHTML.attribute("phx-update") == ["ignore"]
    end

    test "renders the panel in the Favorites tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-favorites > #{@panel}")
    end

    test "hands the panel's hook the most favorites a rider keeps" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> panel() |> LazyHTML.attribute("data-favorite-count-max") ==
               [Integer.to_string(OpenStops.favorite_count_max())]
    end

    test "hands the stops' hook the most popups that open by themselves" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      [count] =
        view
        |> element("#stop-markers")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-auto-open-count-max")

      assert count == Integer.to_string(OpenStops.auto_open_count_max())
    end

    test "hands the stops' hook the most arrivals a stop shows" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      [count] =
        view
        |> element("#stop-markers")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-arrival-count-max")

      assert count == Integer.to_string(GobusgoWeb.StopArrivals.arrival_count_max())
    end
  end

  describe "a favorite's position" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      restart_stop_view()
      on_exit(&restart_stop_view/0)
    end

    test "answers the position of a stop the stop view holds" do
      apply_stop()
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      request_position(view, %{"stop_id" => "1_431"})

      assert_reply(view, %{lat: 47.6101, lon: -122.3378})
    end

    test "refuses a stop the stop view does not hold" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      request_position(view, %{"stop_id" => "1_999"})

      assert_reply(view, %{refused: true})
    end

    test "refuses a request that names no stop" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      request_position(view, %{"stop_id" => 431})

      assert_reply(view, %{refused: true})
    end
  end

  describe "OpenStops.open_count_max/0" do
    test "is room for every favorite and every popup that opens by itself" do
      assert OpenStops.open_count_max() ==
               OpenStops.favorite_count_max() + OpenStops.auto_open_count_max()
    end

    test "keeps six favorites" do
      assert OpenStops.favorite_count_max() == 6
    end
  end

  describe "GET /vehicles without a basemap" do
    test "renders no favorite stop's panel" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel)
    end
  end
end
