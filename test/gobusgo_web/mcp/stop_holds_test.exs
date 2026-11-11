defmodule GobusgoWeb.Mcp.StopHoldsTest do
  # Holds stops in the application's demand registry through the
  # application's hold supervisor and reads what the registry holds through
  # its public reads. Both are global, hence the non-async case; each case
  # releases what it held.
  use ExUnit.Case, async: false

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.Mcp.StopHolds

  @hold_ms 60_000
  @wait_ms 10
  @wait_count_max 200

  setup do
    on_exit(fn -> Enum.each(StopHolds.held_stop_ids(), &StopHolds.release/1) end)
  end

  defp open_stop_ids, do: Demand.items(Demand, DemandKey.arrivals_dataset())

  defp await(check, count \\ @wait_count_max) do
    case {check.(), count} do
      {true, _count} ->
        :ok

      {false, count} when count > 1 ->
        Process.sleep(@wait_ms)
        await(check, count - 1)

      {false, _count} ->
        flunk("the condition did not hold in time")
    end
  end

  test "a fetch for every held stop fits inside a hold" do
    assert StopHolds.hold_count_max() * Sources.arrival_interval_ms() < StopHolds.hold_ms()
  end

  describe "hold/2" do
    test "registers the stop's arrivals key in the demand registry" do
      assert StopHolds.hold("1_1", %{hold_ms: @hold_ms}) == :held

      assert open_stop_ids() == ["1_1"]
      assert StopHolds.held_stop_ids() == ["1_1"]
    end

    test "holds a stop asked for again once" do
      assert StopHolds.hold("1_1", %{hold_ms: @hold_ms}) == :held
      assert StopHolds.hold("1_1", %{hold_ms: @hold_ms}) == :held

      assert Demand.holder_count(Demand, DemandKey.arrivals("1_1")) == 1
    end

    test "ends the hold when its time is up" do
      assert StopHolds.hold("1_1", %{hold_ms: 50}) == :held

      await(fn -> open_stop_ids() == [] end)
      assert StopHolds.held_stop_ids() == []
    end

    test "renewing a hold extends its time" do
      assert StopHolds.hold("1_1", %{hold_ms: 100}) == :held
      assert StopHolds.hold("1_1", %{hold_ms: @hold_ms}) == :held

      Process.sleep(250)

      assert open_stop_ids() == ["1_1"]
    end

    test "refuses a stop beyond the cap and registers nothing for it" do
      stop_ids = for number <- 1..StopHolds.hold_count_max(), do: "1_#{number}"
      for stop_id <- stop_ids, do: assert(StopHolds.hold(stop_id, %{hold_ms: @hold_ms}) == :held)

      assert StopHolds.hold("1_extra", %{hold_ms: @hold_ms}) == :cap_reached

      refute "1_extra" in open_stop_ids()
      assert length(open_stop_ids()) == StopHolds.hold_count_max()
    end

    test "still renews a held stop at the cap" do
      stop_ids = for number <- 1..StopHolds.hold_count_max(), do: "1_#{number}"
      for stop_id <- stop_ids, do: assert(StopHolds.hold(stop_id, %{hold_ms: @hold_ms}) == :held)

      assert StopHolds.hold("1_1", %{hold_ms: @hold_ms}) == :held
    end
  end

  describe "release/1" do
    test "frees the stop's key in the demand registry" do
      :held = StopHolds.hold("1_1", %{hold_ms: @hold_ms})

      assert StopHolds.release("1_1") == :ok

      assert open_stop_ids() == []
      assert StopHolds.held_stop_ids() == []
    end

    test "is ok for a stop that is not held" do
      assert StopHolds.release("1_9") == :ok
    end

    test "makes room under the cap" do
      stop_ids = for number <- 1..StopHolds.hold_count_max(), do: "1_#{number}"
      for stop_id <- stop_ids, do: :held = StopHolds.hold(stop_id, %{hold_ms: @hold_ms})
      :ok = StopHolds.release("1_1")

      assert StopHolds.hold("1_extra", %{hold_ms: @hold_ms}) == :held
    end
  end

  describe "demanded?/1" do
    test "is true for a stop a process of the registry holds" do
      holder =
        spawn_link(fn ->
          :ok = Demand.register(Demand, DemandKey.arrivals("1_1"))
          Process.sleep(:infinity)
        end)

      await(fn -> StopHolds.demanded?("1_1") end)
      Process.unlink(holder)
      Process.exit(holder, :kill)
      await(fn -> not StopHolds.demanded?("1_1") end)
    end

    test "is false for a stop no process holds" do
      refute StopHolds.demanded?("1_1")
    end
  end
end
