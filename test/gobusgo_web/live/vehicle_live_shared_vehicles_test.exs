defmodule GobusgoWeb.VehicleLiveSharedVehiclesTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory, turns the shared vehicle
  # layer on and off with the events its toggle's hook sends, and reads the
  # count of processes that hold the shared vehicles key in the
  # application's demand registry, and the element the browser draws the
  # layer from. The indexes are recorded in the application's tile process.
  # The registry and the process are global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.DemandKey
  alias Gobusgo.Gbfs.VehicleTiles
  alias GobusgoWeb.VehicleLive.SharedVehicles

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @path "/vehicles"
  @layer "#shared-vehicles-layer"
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @destination "shared-vehicles/dt=2026-11-08/system=lime_seattle/20261108T190830Z_0199c4a2-7e1b-7a3f-9d20-000000000001/index-0123456789abcdef.json.gz"

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
    for child <- [Demand, VehicleTiles] do
      # Ignored: the child is already stopped where a test has stopped it.
      _result = Supervisor.terminate_child(Gobusgo.Supervisor, child)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, child)
    end
  end

  defp holder_count, do: Demand.holder_count(Demand, DemandKey.shared_vehicles())

  defp record_index(fetched_at) do
    :ok =
      VehicleTiles.record(VehicleTiles, %{
        system_id: "lime_seattle",
        destination: @destination,
        fetched_at: fetched_at,
        vehicle_count: 2
      })
  end

  defp indexes(view) do
    [indexes] =
      view
      |> element(@layer)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-indexes")

    JSON.decode!(indexes)
  end

  defp show(view), do: render_hook(view, "shared-vehicles:show", %{})
  defp hide(view), do: render_hook(view, "shared-vehicles:hide", %{})

  describe "the demand hold" do
    test "a page holds nothing while the layer is off" do
      {:ok, _view, _html} = live(build_conn(), @path)

      assert holder_count() == 0
    end

    test "turning the layer on holds the shared vehicles key" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert holder_count() == 1
    end

    test "turning the layer on twice holds the key once" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)
      show(view)

      assert holder_count() == 1
    end

    test "turning the layer off releases the key" do
      {:ok, view, _html} = live(build_conn(), @path)
      show(view)

      hide(view)

      assert holder_count() == 0
    end

    test "closing the page releases the key" do
      {:ok, view, _html} = live(build_conn(), @path)
      show(view)
      Process.flag(:trap_exit, true)
      reference = Process.monitor(view.pid)

      Process.exit(view.pid, :shutdown)

      assert_receive {:DOWN, ^reference, :process, _pid, _reason}
      assert holder_count() == 0
    end

    test "a page holds the key again when the registry restarts" do
      {:ok, view, _html} = live(build_conn(), @path)
      show(view)
      _result = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, Demand)

      # The page registers in its own time once it sees the registry go down.
      _rendered = render(view)

      assert Enum.any?(1..100//1, fn _check ->
               Process.sleep(10)
               holder_count() == 1
             end)
    end
  end

  describe "the layer's indexes" do
    test "hands the browser no index while the layer is off" do
      record_index(DateTime.utc_now())
      {:ok, view, _html} = live(build_conn(), @path)

      assert indexes(view) == []
    end

    test "hands the browser the current index once the layer is on" do
      record_index(DateTime.utc_now())
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert indexes(view) == [
               %{
                 "url" => "/" <> @destination,
                 "system_id" => "lime_seattle",
                 "operator_name" => "Lime"
               }
             ]
    end

    test "follows an index recorded while the layer is on" do
      {:ok, view, _html} = live(build_conn(), @path)
      show(view)

      record_index(DateTime.utc_now())

      assert [%{"url" => "/" <> @destination}] = indexes(view)
    end

    test "hands the browser no index of a fetch past the age a page draws" do
      age_ms = SharedVehicles.fetch_age_ms_max() + 1
      record_index(DateTime.add(DateTime.utc_now(), -age_ms, :millisecond))
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert indexes(view) == []
    end
  end

  describe "what the page says" do
    test "says the layer is loading before a first fetch" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert view |> element("#shared-vehicles-status") |> render() =~ "Loading"
    end

    test "says there is nothing to show once the wait for a fetch is over" do
      assert SharedVehicles.status(%{
               indexes: [],
               shown_ms_ago: SharedVehicles.first_fetch_wait_ms()
             }) ==
               :none
    end

    test "says when the layer shows" do
      record_index(DateTime.utc_now())
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert view |> element("#shared-vehicles-status") |> render() =~ "zoomed in"
    end

    test "says nothing while the layer is off" do
      {:ok, view, _html} = live(build_conn(), @path)

      refute has_element?(view, "#shared-vehicles-status")
    end

    test "gives each kind of shared vehicle a letter of its own" do
      letters = Enum.map(SharedVehicles.form_colors(), & &1.letter)

      assert Enum.uniq(letters) == letters
      assert Enum.all?(letters, &(String.length(&1) == 1))
    end

    test "shows each kind's letter in its swatch in the legend" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      for %{form_factor: form_factor, letter: letter} <- SharedVehicles.form_colors() do
        swatch = "#shared-vehicles-legend [data-form-factor=#{form_factor}]"
        assert view |> element(swatch) |> render() =~ letter
      end
    end

    test "shows the low-range swatch in the legend" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert has_element?(view, "#shared-vehicles-legend #shared-vehicles-low-range")
    end

    test "renders the toggle checked once the layer is on" do
      {:ok, view, _html} = live(build_conn(), @path)

      show(view)

      assert has_element?(view, "#shared-vehicles-shown[checked]")
    end
  end
end
