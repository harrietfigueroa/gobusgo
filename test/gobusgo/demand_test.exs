defmodule Gobusgo.DemandTest do
  # Starts a registry per test and registers keys from the test process and
  # from processes the test starts and ends, so what the registry does when
  # a holder goes away is observed through items/2 and holder_count/2.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Demand

  @datasets [:arrivals, :vehicles]
  @vehicles {:vehicles, "all"}
  @item_count_max_default 2_000
  @holder_item_count_max_default 4

  # The registry reads a clock the test owns, which stands still until the
  # test advances it.
  setup context do
    registry = Module.concat(__MODULE__, "Registry#{context.line}")
    clock = :atomics.new(1, signed: true)

    start_supervised!(
      {Demand,
       name: registry,
       datasets: @datasets,
       item_count_max: 2,
       holder_item_count_max: 2,
       monotonic_time_ms: fn -> :atomics.get(clock, 1) end}
    )

    %{registry: registry, clock: clock}
  end

  # A process that registers `key` and then waits to be told to release it
  # or to exit.
  defp holder(registry, key) do
    test_pid = self()

    pid =
      spawn(fn ->
        send(test_pid, {:registered, self(), Demand.register(registry, key)})

        receive do
          :release ->
            send(test_pid, {:released, self(), Demand.release(registry, key)})

            receive do
              :exit -> :ok
            end

          :exit ->
            :ok
        end
      end)

    assert_receive {:registered, ^pid, result}
    {pid, result}
  end

  defp exit_and_wait(pid) do
    reference = Process.monitor(pid)
    send(pid, :exit)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
  end

  defp kill_and_wait(pid) do
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^reference, :process, ^pid, :killed}
  end

  # Reads the count of holders until nobody holds `key`: the registry
  # learns of a holder's exit in its own time, and reads its clock then.
  defp await_no_holder(registry, key, reads_left \\ 500) do
    case Demand.holder_count(registry, key) do
      0 ->
        :ok

      count when reads_left > 1 ->
        assert count >= 1
        Process.sleep(1)
        await_no_holder(registry, key, reads_left - 1)

      count ->
        flunk("expected no holder, got: #{count}")
    end
  end

  defp call(:register, registry), do: Demand.register(registry, {:routes, "1_100"})
  defp call(:release, registry), do: Demand.release(registry, {:routes, "1_100"})
  defp call(:items, registry), do: Demand.items(registry, :routes)
  defp call(:holder_count, registry), do: Demand.holder_count(registry, {:routes, "1_100"})
  defp call(:holding, registry), do: Demand.holding(registry, {:routes, "1_100"})

  test "no dataset has an item at first", %{registry: registry} do
    assert Demand.items(registry, :arrivals) == []
  end

  test "an item the calling process registers is an item of its dataset", %{registry: registry} do
    assert Demand.register(registry, {:arrivals, "1_100"}) == :ok
    assert Demand.items(registry, :arrivals) == ["1_100"]
  end

  test "the items of a dataset leave out those of another", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_100"})
    :ok = Demand.register(registry, @vehicles)

    assert Demand.items(registry, :arrivals) == ["1_100"]
  end

  test "registering a key twice is one registration", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_100"})

    assert Demand.register(registry, {:arrivals, "1_100"}) == :ok
    assert Demand.release(registry, {:arrivals, "1_100"}) == :ok
    assert Demand.items(registry, :arrivals) == []
  end

  test "an item the calling process releases is gone", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_100"})

    assert Demand.release(registry, {:arrivals, "1_100"}) == :ok
    assert Demand.items(registry, :arrivals) == []
  end

  test "releasing a key that is not registered is ok", %{registry: registry} do
    assert Demand.release(registry, {:arrivals, "1_100"}) == :ok
  end

  test "an item stays while another process holds its key", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_100"})
    {pid, :ok} = holder(registry, {:arrivals, "1_100"})

    send(pid, :release)
    assert_receive {:released, ^pid, :ok}

    assert Demand.items(registry, :arrivals) == ["1_100"]
  end

  test "a process that exits releases the keys it held", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_200"})
    {pid, :ok} = holder(registry, {:arrivals, "1_100"})
    assert Demand.items(registry, :arrivals) == ["1_100", "1_200"]

    exit_and_wait(pid)

    assert Demand.items(registry, :arrivals) == ["1_200"]
  end

  test "a process that released its keys and then exits changes nothing", %{registry: registry} do
    :ok = Demand.register(registry, {:arrivals, "1_200"})
    {pid, :ok} = holder(registry, {:arrivals, "1_100"})
    send(pid, :release)
    assert_receive {:released, ^pid, :ok}

    exit_and_wait(pid)

    assert Demand.items(registry, :arrivals) == ["1_200"]
  end

  describe "holder_count/2" do
    test "is zero for a key no process holds", %{registry: registry} do
      assert Demand.holder_count(registry, @vehicles) == 0
    end

    test "counts the processes that hold the key", %{registry: registry} do
      :ok = Demand.register(registry, @vehicles)
      {_pid, :ok} = holder(registry, @vehicles)

      assert Demand.holder_count(registry, @vehicles) == 2
    end

    test "counts a process that registers the key twice once", %{registry: registry} do
      :ok = Demand.register(registry, @vehicles)
      :ok = Demand.register(registry, @vehicles)

      assert Demand.holder_count(registry, @vehicles) == 1
    end

    test "drops when a process releases the key", %{registry: registry} do
      :ok = Demand.register(registry, @vehicles)
      {pid, :ok} = holder(registry, @vehicles)

      send(pid, :release)
      assert_receive {:released, ^pid, :ok}

      assert Demand.holder_count(registry, @vehicles) == 1
    end

    test "drops when a process that holds the key exits", %{registry: registry} do
      :ok = Demand.register(registry, @vehicles)
      {pid, :ok} = holder(registry, @vehicles)

      exit_and_wait(pid)

      assert Demand.holder_count(registry, @vehicles) == 1
    end

    test "drops when a process that holds the key is killed", %{registry: registry} do
      :ok = Demand.register(registry, @vehicles)
      {pid, :ok} = holder(registry, @vehicles)

      kill_and_wait(pid)

      assert Demand.holder_count(registry, @vehicles) == 1
    end
  end

  describe "holding/2" do
    test "is no holder and no absence for a key no process has held", %{registry: registry} do
      assert Demand.holding(registry, @vehicles) == %{holder_count: 0, holder_absence_ms: nil}
    end

    test "is the count of holders and an absence of zero while the key is held", context do
      :ok = Demand.register(context.registry, @vehicles)
      :atomics.add(context.clock, 1, 500)

      assert Demand.holding(context.registry, @vehicles) ==
               %{holder_count: 1, holder_absence_ms: 0}
    end

    test "counts the absence from the release of the last holder", context do
      :ok = Demand.register(context.registry, @vehicles)
      :atomics.add(context.clock, 1, 500)
      :ok = Demand.release(context.registry, @vehicles)
      :atomics.add(context.clock, 1, 700)

      assert Demand.holding(context.registry, @vehicles) ==
               %{holder_count: 0, holder_absence_ms: 700}
    end

    test "counts the absence from the exit of the last holder", context do
      {pid, :ok} = holder(context.registry, @vehicles)
      :atomics.add(context.clock, 1, 500)
      kill_and_wait(pid)
      await_no_holder(context.registry, @vehicles)
      :atomics.add(context.clock, 1, 700)

      assert Demand.holding(context.registry, @vehicles) ==
               %{holder_count: 0, holder_absence_ms: 700}
    end
  end

  describe "bounds" do
    test "refuses an item beyond the count of items of its dataset", %{registry: registry} do
      {_first, :ok} = holder(registry, {:arrivals, "1_1"})
      {_second, :ok} = holder(registry, {:arrivals, "1_2"})

      assert Demand.register(registry, {:arrivals, "1_3"}) == {:error, :item_count_exceeded}
      assert Demand.items(registry, :arrivals) == ["1_1", "1_2"]
    end

    test "takes an item of another dataset beside a dataset at its bound", %{registry: registry} do
      {_first, :ok} = holder(registry, {:arrivals, "1_1"})
      {_second, :ok} = holder(registry, {:arrivals, "1_2"})

      assert Demand.register(registry, @vehicles) == :ok
    end

    test "takes an item into the place a process that exited left", %{registry: registry} do
      {first, :ok} = holder(registry, {:arrivals, "1_1"})
      {_second, :ok} = holder(registry, {:arrivals, "1_2"})
      exit_and_wait(first)

      assert Demand.register(registry, {:arrivals, "1_3"}) == :ok
      assert Demand.items(registry, :arrivals) == ["1_2", "1_3"]
    end

    test "refuses a process's item beyond its own count in the dataset", context do
      registry = Module.concat(__MODULE__, "Roomy#{context.line}")

      start_supervised!({Demand, name: registry, datasets: @datasets, holder_item_count_max: 2},
        id: registry
      )

      :ok = Demand.register(registry, {:arrivals, "1_1"})
      :ok = Demand.register(registry, {:arrivals, "1_2"})

      assert Demand.register(registry, {:arrivals, "1_3"}) ==
               {:error, :holder_item_count_exceeded}
    end

    test "takes a process's item of another dataset beside its own count", %{registry: registry} do
      :ok = Demand.register(registry, {:arrivals, "1_1"})
      :ok = Demand.register(registry, {:arrivals, "1_2"})

      assert Demand.register(registry, @vehicles) == :ok
    end
  end

  describe "default bounds" do
    setup context do
      registry = Module.concat(__MODULE__, "Default#{context.line}")
      start_supervised!({Demand, name: registry, datasets: @datasets}, id: registry)
      %{registry: registry}
    end

    test "one process holds 4 items of a dataset and is refused a fifth", %{registry: registry} do
      for index <- 1..@holder_item_count_max_default do
        assert Demand.register(registry, {:arrivals, "1_#{index}"}) == :ok
      end

      assert Demand.register(registry, {:arrivals, "1_0"}) ==
               {:error, :holder_item_count_exceeded}
    end

    test "a dataset holds 2,000 items and refuses one more", %{registry: registry} do
      1..@item_count_max_default
      |> Enum.chunk_every(@holder_item_count_max_default)
      |> Enum.each(fn indexes ->
        test_pid = self()

        pid =
          spawn_link(fn ->
            results = Enum.map(indexes, &Demand.register(registry, {:arrivals, "1_#{&1}"}))
            send(test_pid, {:registered, self(), results})
            Process.sleep(:infinity)
          end)

        assert_receive {:registered, ^pid, [:ok, :ok, :ok, :ok]}
      end)

      assert length(Demand.items(registry, :arrivals)) == @item_count_max_default
      assert Demand.register(registry, {:arrivals, "1_0"}) == {:error, :item_count_exceeded}
    end
  end

  describe "invalid input" do
    test "raises for an empty item", %{registry: registry} do
      assert_raise AssertionError, ~r/item/, fn -> Demand.register(registry, {:arrivals, ""}) end
    end

    for function <- [:register, :release, :items, :holder_count, :holding] do
      test "#{function} raises in the caller for a dataset the registry does not admit",
           %{registry: registry} do
        :ok = Demand.register(registry, {:arrivals, "1_100"})

        assert_raise AssertionError, ~r/dataset/, fn -> call(unquote(function), registry) end

        assert Demand.items(registry, :arrivals) == ["1_100"]
      end
    end

    test "does not start with a clock that is not a zero-arity function" do
      assert_raise AssertionError, ~r/monotonic_time_ms/, fn ->
        Demand.start_link(
          name: Module.concat(__MODULE__, NoClock),
          datasets: @datasets,
          monotonic_time_ms: :not_a_function
        )
      end
    end

    test "does not start with no dataset" do
      Process.flag(:trap_exit, true)

      assert {:error, {%AssertionError{}, _stacktrace}} =
               Demand.start_link(name: Module.concat(__MODULE__, NoDataset), datasets: [])
    end
  end
end
