defmodule GobusgoWeb.VehicleLiveRouteStopTilesTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory, the application's route view,
  # filled with the record values its records module builds, and the
  # application's tile archive process, given an archive by `record/2`. All
  # are global state, hence the non-async case. The browser draws the lines
  # and the stops from the archive, so these tests observe the element that
  # carries the archive's address and the routes the filter keeps.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias GobusgoWeb.RouteStopTiles

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @element "#route-stop-tiles"
  @push_wait_ms 50
  @route_view Gobusgo.OneBusAway.RouteView
  @fetched_at ~U[2026-10-05 01:00:00Z]
  @destination "tiles/route-stops/dt=2026-10-05/route-stops-20261005T010000000000Z.pmtiles"
  @later_destination "tiles/route-stops/dt=2026-10-05/route-stops-20261005T011000000000Z.pmtiles"
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
    restart_children()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_children()
    end)
  end

  defp restart_children do
    for child <- [@route_view, RouteStopTiles] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, child)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, child)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  # Publishes a fetch of the routes of `agency_id`; `sequence` orders the
  # fetches of a test.
  defp apply_routes(route_ids, %{agency_id: agency_id, sequence: sequence}) do
    record =
      RouteBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=#{agency_id}/file.json.gz",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        routes:
          for id <- route_ids do
            %{
              id: id,
              agency_id: agency_id,
              short_name: nil,
              long_name: nil,
              description: nil,
              type: 3,
              color: nil,
              text_color: nil,
              url: nil
            }
          end
      })

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  defp record_archive(destination) do
    :ok =
      RouteStopTiles.record(RouteStopTiles, %{
        destination: destination,
        content_sha256: :crypto.hash(:sha256, destination),
        built_at: DateTime.utc_now()
      })
  end

  defp open_page(path) do
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  # An attribute of the element, or `nil` where it has none.
  defp attribute(view, name) do
    view
    |> element(@element)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> case do
      [value] -> value
      [] -> nil
    end
  end

  defp kept_route_ids(view) do
    case attribute(view, "data-route-ids") do
      nil -> :every
      value -> JSON.decode!(value)
    end
  end

  describe "the page" do
    test "holds the element the tile hook mounts on, shown as nothing" do
      html = open_page("/vehicles") |> element(@element) |> render()

      assert html =~ ~s(phx-hook="RouteStopTiles")
      assert html =~ "hidden"
    end

    test "holds no tile element when there is no basemap", %{tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "manifest.json"))

      refute open_page("/vehicles") |> has_element?(@element)
    end

    test "sends no line and no stop event" do
      apply_routes(["1_100"], %{agency_id: "1", sequence: 1})
      view = open_page("/vehicles")

      render_patch(view, "/vehicles?agency=1")

      refute_push_event(view, "route-lines:routes", %{}, @push_wait_ms)
      refute_push_event(view, "stop-markers:stops", %{}, @push_wait_ms)
    end
  end

  describe "the archive's address" do
    test "is none while there is no archive" do
      assert attribute(open_page("/vehicles"), "data-archive-url") == nil
    end

    test "is the current archive's, under the site's root" do
      record_archive(@destination)

      assert attribute(open_page("/vehicles"), "data-archive-url") == "/" <> @destination
    end

    test "is in the page's first render, before the socket connects" do
      record_archive(@destination)

      html = build_conn() |> get("/vehicles") |> html_response(200)

      assert html =~ ~s(data-archive-url="/#{@destination}")
    end

    test "follows a newer archive when the filter changes" do
      record_archive(@destination)
      view = open_page("/vehicles")
      record_archive(@later_destination)

      render_patch(view, "/vehicles?agency=1")

      assert attribute(view, "data-archive-url") == "/" <> @later_destination
    end
  end

  describe "the kept routes" do
    setup do
      apply_routes(["1_200", "1_100"], %{agency_id: "1", sequence: 1})
      apply_routes(["40_500"], %{agency_id: "40", sequence: 2})
    end

    for {name, path, kept} <- [
          {"are every route, named by no list, without a filter", "/vehicles", :every},
          {"are the routes of the kept agency, in identifier order", "/vehicles?agency=1",
           ["1_100", "1_200"]},
          {"are the routes the filter names", "/vehicles?route=40_500", ["40_500"]},
          {"are a named route of a named agency", "/vehicles?agency=40&route=40_500", ["40_500"]},
          {"are none for a route whose agency the filter leaves out",
           "/vehicles?agency=1&route=40_500", []},
          {"are none for a route that no agency lists", "/vehicles?route=1_999", []},
          {"are none for a refused filter", "/vehicles?agency[x]=1", []}
        ] do
      test name do
        assert kept_route_ids(open_page(unquote(path))) == unquote(Macro.escape(kept))
      end
    end

    test "change with the filter" do
      view = open_page("/vehicles?agency=40")

      render_patch(view, "/vehicles?agency=1")

      assert kept_route_ids(view) == ["1_100", "1_200"]
    end

    test "take in a route a new fetch of a kept agency lists" do
      view = open_page("/vehicles?agency=1")

      apply_routes(["1_100", "1_200", "1_300"], %{agency_id: "1", sequence: 3})

      assert kept_route_ids(view) == ["1_100", "1_200", "1_300"]
    end

    test "leave out the routes of a new fetch of an agency the filter leaves out" do
      view = open_page("/vehicles?agency=1")

      apply_routes(["40_500", "40_600"], %{agency_id: "40", sequence: 3})

      assert kept_route_ids(view) == ["1_100", "1_200"]
    end
  end
end
