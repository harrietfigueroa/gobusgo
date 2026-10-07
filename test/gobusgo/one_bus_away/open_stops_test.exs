defmodule Gobusgo.OneBusAway.OpenStopsTest do
  # Starts a registry per test and opens stops from the test process and
  # from processes the test starts and ends, so what the registry does when
  # an opener goes away is observed through stop_ids/1.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.OpenStops

  setup context do
    registry = Module.concat(__MODULE__, "Registry#{context.line}")
    start_supervised!({OpenStops, name: registry, stop_count_max: 2, opener_stop_count_max: 2})
    %{registry: registry}
  end

  # A process that opens `stop_id` and then waits to be told to close it or
  # to exit.
  defp opener(registry, stop_id) do
    test_pid = self()

    pid =
      spawn(fn ->
        send(test_pid, {:opened, self(), OpenStops.open(registry, stop_id)})

        receive do
          :close ->
            send(test_pid, {:closed, self(), OpenStops.close(registry, stop_id)})

            receive do
              :exit -> :ok
            end

          :exit ->
            :ok
        end
      end)

    assert_receive {:opened, ^pid, result}
    {pid, result}
  end

  defp exit_and_wait(pid) do
    reference = Process.monitor(pid)
    send(pid, :exit)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
  end

  test "no stop is open at first", %{registry: registry} do
    assert OpenStops.stop_ids(registry) == []
  end

  test "a stop the calling process opens is open", %{registry: registry} do
    assert OpenStops.open(registry, "1_100") == :ok
    assert OpenStops.stop_ids(registry) == ["1_100"]
  end

  test "opening a stop twice is one opening", %{registry: registry} do
    :ok = OpenStops.open(registry, "1_100")

    assert OpenStops.open(registry, "1_100") == :ok
    assert OpenStops.close(registry, "1_100") == :ok
    assert OpenStops.stop_ids(registry) == []
  end

  test "a stop the calling process closes is closed", %{registry: registry} do
    :ok = OpenStops.open(registry, "1_100")

    assert OpenStops.close(registry, "1_100") == :ok
    assert OpenStops.stop_ids(registry) == []
  end

  test "closing a stop that is not open is ok", %{registry: registry} do
    assert OpenStops.close(registry, "1_100") == :ok
  end

  test "a stop stays open while another process has it open", %{registry: registry} do
    :ok = OpenStops.open(registry, "1_100")
    {pid, :ok} = opener(registry, "1_100")

    send(pid, :close)
    assert_receive {:closed, ^pid, :ok}

    assert OpenStops.stop_ids(registry) == ["1_100"]
  end

  test "a process that exits closes the stops it had open", %{registry: registry} do
    :ok = OpenStops.open(registry, "1_200")
    {pid, :ok} = opener(registry, "1_100")
    assert OpenStops.stop_ids(registry) == ["1_100", "1_200"]

    exit_and_wait(pid)

    assert OpenStops.stop_ids(registry) == ["1_200"]
  end

  test "a process that closed its stops and then exits changes nothing", %{registry: registry} do
    :ok = OpenStops.open(registry, "1_200")
    {pid, :ok} = opener(registry, "1_100")
    send(pid, :close)
    assert_receive {:closed, ^pid, :ok}

    exit_and_wait(pid)

    assert OpenStops.stop_ids(registry) == ["1_200"]
  end

  describe "bounds" do
    test "refuses a stop beyond the count of open stops", %{registry: registry} do
      {_first, :ok} = opener(registry, "1_1")
      {_second, :ok} = opener(registry, "1_2")

      assert OpenStops.open(registry, "1_3") == {:error, :stop_count_exceeded}
      assert OpenStops.stop_ids(registry) == ["1_1", "1_2"]
    end

    test "takes a stop into the place a process that exited left", %{registry: registry} do
      {first, :ok} = opener(registry, "1_1")
      {_second, :ok} = opener(registry, "1_2")
      exit_and_wait(first)

      assert OpenStops.open(registry, "1_3") == :ok
      assert OpenStops.stop_ids(registry) == ["1_2", "1_3"]
    end

    test "refuses a process's stop beyond its own count", context do
      registry = Module.concat(__MODULE__, "Roomy#{context.line}")
      start_supervised!({OpenStops, name: registry, opener_stop_count_max: 2}, id: registry)
      :ok = OpenStops.open(registry, "1_1")
      :ok = OpenStops.open(registry, "1_2")

      assert OpenStops.open(registry, "1_3") == {:error, :opener_stop_count_exceeded}
    end
  end

  test "raises for an empty stop identifier", %{registry: registry} do
    assert_raise AssertionError, ~r/stop identifier/, fn -> OpenStops.open(registry, "") end
  end
end
