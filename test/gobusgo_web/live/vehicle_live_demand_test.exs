defmodule GobusgoWeb.VehicleLiveDemandTest do
  # Requests the vehicle page as the plain HTTP response and mounts it with
  # Phoenix.LiveViewTest, then reads the count of processes that hold the
  # vehicles key in the application's demand registry. The registry is
  # global state, hence the non-async case. The page has no basemap here and
  # says so, which leaves its registration as it is.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @path "/vehicles"

  setup do
    restart_registry()
    on_exit(&restart_registry/0)
  end

  defp restart_registry do
    # Ignored: the child is already stopped where a test has stopped it.
    _result = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, Demand)
  end

  defp viewer_count, do: Demand.holder_count(Demand, DemandKey.vehicles())

  # Ends the page's process with `exit_reason` and waits until it is gone.
  # The test traps exits because the test's connection to the page is linked
  # to it.
  defp end_page(view, exit_reason) do
    Process.flag(:trap_exit, true)
    reference = Process.monitor(view.pid)
    Process.exit(view.pid, exit_reason)
    assert_receive {:DOWN, ^reference, :process, _pid, _reason}
  end

  test "the static render registers nothing" do
    assert build_conn() |> get(@path) |> html_response(200) =~ "No basemap"

    assert viewer_count() == 0
  end

  test "a connected page counts as one viewer of vehicles" do
    {:ok, _view, _html} = live(build_conn(), @path)

    assert viewer_count() == 1
  end

  test "each connected page counts as a viewer" do
    {:ok, _first, _html} = live(build_conn(), @path)
    {:ok, _second, _html} = live(build_conn(), @path)

    assert viewer_count() == 2
  end

  for {name, exit_reason} <- [{"shuts down", :shutdown}, {"crashes", :kill}] do
    test "the count drops when a page's process #{name}" do
      {:ok, _staying, _html} = live(build_conn(), @path)
      {:ok, leaving, _html} = live(build_conn(), @path)
      assert viewer_count() == 2

      end_page(leaving, unquote(exit_reason))

      assert viewer_count() == 1
    end
  end

  describe "a registry that refuses the page's registration" do
    setup do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)

      start_supervised!({Demand, name: Demand, datasets: DemandKey.datasets(), item_count_max: 1})

      {dataset, item} = DemandKey.vehicles()
      :ok = Demand.register(Demand, {dataset, item <> "-other"})
    end

    test "leaves the page mounted and not counted" do
      {:ok, view, _html} = live(build_conn(), @path)

      assert render(view) =~ "No basemap"
      assert viewer_count() == 0
    end
  end
end
