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
  alias Gobusgo.Test.AppEnv

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @path "/vehicles"
  @count_check_interval_ms 20
  @count_check_count_max 250
  @registry_down_ms 1_000

  setup %{tmp_dir: tmp_dir} do
    AppEnv.isolate_data(tmp_dir)
    restart_registry()
    on_exit(&restart_registry/0)
  end

  # Stops the registry and starts another under its supervisor, which is
  # what a page sees of a registry that crashes, and counts for nothing in
  # the supervisor's bound on restarts.
  defp restart_registry do
    # Ignored: the child is already stopped where a test has stopped it.
    _result = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, Demand)
  end

  defp viewer_count, do: Demand.holder_count(Demand, DemandKey.vehicles())

  # Reads the count until it is `expected`, for the page registers in its
  # own time after the registry is back, and gives up after
  # @count_check_count_max reads.
  defp await_viewer_count(expected, checks_left \\ @count_check_count_max) do
    case viewer_count() do
      ^expected ->
        :ok

      count when checks_left > 1 ->
        assert is_integer(count)
        Process.sleep(@count_check_interval_ms)
        await_viewer_count(expected, checks_left - 1)

      count ->
        flunk("expected #{expected} viewers, got: #{count}")
    end
  end

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

  describe "a registry that restarts" do
    test "counts the page that was connected before, which stays mounted" do
      {:ok, view, _html} = live(build_conn(), @path)
      assert viewer_count() == 1

      restart_registry()

      assert await_viewer_count(1) == :ok
      assert render(view) =~ "No basemap"
    end

    test "counts every page that was connected before" do
      {:ok, _first, _html} = live(build_conn(), @path)
      {:ok, _second, _html} = live(build_conn(), @path)

      restart_registry()

      assert await_viewer_count(2) == :ok
    end

    test "counts a page once however often the registry restarts" do
      {:ok, _view, _html} = live(build_conn(), @path)

      restart_registry()
      assert await_viewer_count(1) == :ok
      restart_registry()

      assert await_viewer_count(1) == :ok
    end
  end

  describe "a registry that is down when the page connects" do
    test "leaves the page mounted, and counts it once the registry is back" do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)
      {:ok, view, _html} = live(build_conn(), @path)
      assert render(view) =~ "No basemap"

      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, Demand)

      assert await_viewer_count(1) == :ok
    end

    # The registry stays down for @registry_down_ms, twice as long as the
    # page keeps trying.
    test "is logged as a warning once the page has stopped trying" do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)

      log =
        ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
          {:ok, view, _html} = live(build_conn(), @path)
          Process.sleep(@registry_down_ms)
          render(view)
        end)

      assert log =~ "[warning] Vehicle page not counted as a viewer"
      assert log =~ "refusal=registry_unavailable"
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
