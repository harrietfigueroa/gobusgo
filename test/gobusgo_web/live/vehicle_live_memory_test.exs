defmodule GobusgoWeb.VehicleLiveMemoryTest do
  # Measures the memory the vehicle page holds on the server and prints it.
  # The test fills the application's vehicle view with one fetch cycle of
  # synthetic vehicles in the counts a real cycle had, its two route views
  # with synthetic routes and paths in the counts of a real day, and its stop
  # view with synthetic stops in about the count of a real day, mounts the
  # page with
  # Phoenix.LiveViewTest over a basemap manifest in its temporary directory,
  # and applies further cycles while the page is open. It reads the page
  # process, the view process, and the view's table after the first draw and
  # after the last cycle, each as found and again after a forced collection,
  # so the difference is the garbage a process was still holding. The view
  # and the basemap setting are global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Test.VehiclePageMemory

  @moduletag :memory
  @moduletag :tmp_dir
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  @endpoint GobusgoWeb.Endpoint
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView

  # One minute of the vehicle source's five-second cycles.
  @cycle_count 12
  @bytes_per_kibibyte 1024
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
    restart_views()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_views()
    end)
  end

  defp restart_views do
    for view <- [VehicleView, @route_view, @route_path_view, StopView] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp apply_cycle(sequence) do
    for %{agency_id: agency_id, vehicle_count: vehicle_count} <-
          VehiclePageMemory.fetch_profile() do
      :ok =
        VehiclePageMemory.apply_fetch(VehicleView, %{
          agency_id: agency_id,
          vehicle_count: vehicle_count,
          sequence: sequence
        })
    end
  end

  # A process's reading as found, then after a collection of that process.
  defp readings(label, pid) do
    found = VehiclePageMemory.process_memory(pid)
    true = :erlang.garbage_collect(pid)
    collected = VehiclePageMemory.process_memory(pid)

    [{label <> ", as found", found}, {label <> ", collected", collected}]
  end

  defp measure(view) do
    # Rendering is a call to the page process, so it returns after the page
    # has handled every announcement sent before it.
    _html = render(view)

    %{
      processes:
        readings("page process", view.pid) ++
          readings("view process", Process.whereis(VehicleView)),
      table_bytes: VehiclePageMemory.table_memory_bytes(VehicleView)
    }
  end

  defp print(title, %{processes: processes, table_bytes: table_bytes}) do
    rows =
      for {label, memory} <- processes do
        "  #{String.pad_trailing(label, 26)}" <>
          " memory #{kibibytes(memory.memory_bytes)}" <>
          " heap #{kibibytes(memory.heap_bytes)}" <>
          " binaries #{kibibytes(memory.binary_bytes)}"
      end

    table_row = "  #{String.pad_trailing("view table", 26)} memory #{kibibytes(table_bytes)}"
    IO.puts(Enum.join([title | rows] ++ [table_row], "\n"))
  end

  defp kibibytes(bytes) do
    kibibyte_count = div(bytes, @bytes_per_kibibyte)
    String.pad_leading("#{kibibyte_count} KiB", 11)
  end

  test "prints the memory of the page, the view, and the view's table" do
    profile = VehiclePageMemory.fetch_profile()
    vehicle_count = Enum.sum_by(profile, & &1.vehicle_count)
    apply_cycle(0)

    route_count =
      VehiclePageMemory.apply_routes(%{
        route_view: @route_view,
        route_path_view: @route_path_view
      })

    stop_count = VehiclePageMemory.apply_stops(StopView)

    {:ok, view, _html} = live(build_conn(), "/vehicles")
    view |> element("#vehicle-markers") |> render_hook("vehicle-markers:ready")
    first_draw = measure(view)

    for sequence <- 1..@cycle_count do
      apply_cycle(sequence)
      _html = render(view)
    end

    last_cycle = measure(view)
    retention = VehiclePageMemory.identifier_retention(VehicleView)

    IO.puts(
      "\nVehicle page memory: #{vehicle_count} vehicles, #{length(profile)} agencies," <>
        " #{route_count} routes, #{stop_count} stops"
    )

    print("After the first draw", first_draw)
    print("After #{@cycle_count} more fetch cycles", last_cycle)

    IO.puts(
      "Stop view: table #{kibibytes(VehiclePageMemory.table_memory_bytes(StopView))}," <>
        " process #{kibibytes(VehiclePageMemory.process_memory(Process.whereis(StopView)).memory_bytes)}"
    )

    IO.puts(
      "Vehicle identifiers in the view table: #{retention.identifier_bytes} bytes," <>
        " keeping #{retention.referenced_bytes} bytes alive"
    )

    assert VehicleView
           |> VehicleView.current()
           |> Enum.sum_by(&length(&1.vehicle_ids)) == vehicle_count
  end
end
