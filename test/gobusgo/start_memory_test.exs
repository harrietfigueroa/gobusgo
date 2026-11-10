defmodule Gobusgo.StartMemoryTest do
  # Hands the check's rules literal memory.stat text, log lines, and step
  # outcomes, and compares what they decide with the case each one states.
  use ExUnit.Case, async: true

  alias Gobusgo.StartMemory

  @mib 1024 * 1024

  describe "anon_bytes/1" do
    test "reads the anon line of a cgroup v2 memory.stat" do
      text = "anon 644245094\nfile 12288\nkernel 3145728\nanon_thp 0\n"
      assert StartMemory.anon_bytes(text) == {:ok, 644_245_094}
    end

    test "returns :error for text with no anon line, as a cgroup v1 memory.stat" do
      assert StartMemory.anon_bytes("cache 12288\nrss 644245094\n") == :error
    end

    test "returns :error for an anon line whose value is not a whole number" do
      assert StartMemory.anon_bytes("anon 12kB\n") == :error
    end
  end

  describe "event/1" do
    for {line, event} <- [
          {"02:41:07.123 [info] Routing snapshots built built_count=2", :snapshots_built},
          {"02:41:07.123 [error] Routing snapshots not built failed_count=1", :snapshots_failed},
          {"02:41:07.123 [error] Routing snapshot build killed service_date=2026-11-09",
           :snapshots_failed},
          {"02:41:09.456 [info] Route stop tiles built route_count=390", :tiles_built},
          {"02:41:09.456 [error] Route stop tiles not built reason=:timeout", :tiles_failed},
          {"02:41:00.000 [info] Route schedule view rebuilt processed_count=629", :none}
        ] do
      test "reads #{inspect(event)} from #{inspect(line)}" do
        assert StartMemory.event(unquote(line)) == unquote(event)
      end
    end
  end

  describe "ending/1" do
    test "is :running while a step is awaited" do
      assert StartMemory.ending(MapSet.new([:snapshots_built])) == :running
    end

    test "is :built once both steps logged their success" do
      assert StartMemory.ending(MapSet.new([:snapshots_built, :tiles_built])) == :built
    end

    test "names the step that logged its failure, whatever else was built" do
      events = MapSet.new([:snapshots_built, :tiles_failed])
      assert StartMemory.ending(events) == {:step_failed, :tiles_failed}
    end
  end

  describe "verdict/1" do
    test "passes a built start whose peak is at the limit" do
      assert StartMemory.verdict(%{ending: :built, peak_bytes: 900 * @mib, anon_mib_max: 900}) ==
               :passed
    end

    test "fails a built start whose peak is a byte past the limit, naming the peak rounded up" do
      verdict =
        StartMemory.verdict(%{ending: :built, peak_bytes: 900 * @mib + 1, anon_mib_max: 900})

      assert verdict == {:failed, {:peak_exceeded, 901}}
    end

    test "passes a built start whose peak is 700 MiB under the default limit" do
      verdict =
        StartMemory.verdict(%{
          ending: :built,
          peak_bytes: 700 * @mib,
          anon_mib_max: StartMemory.anon_mib_max()
        })

      assert verdict == :passed
    end

    test "fails a built start whose peak is a byte past 700 MiB under the default limit" do
      verdict =
        StartMemory.verdict(%{
          ending: :built,
          peak_bytes: 700 * @mib + 1,
          anon_mib_max: StartMemory.anon_mib_max()
        })

      assert verdict == {:failed, {:peak_exceeded, 701}}
    end

    for ending <- [:out_of_memory, :deadline, {:exited, 1}, {:step_failed, :snapshots_failed}] do
      test "fails a start that ended with #{inspect(ending)}, whatever its peak" do
        assert StartMemory.verdict(%{ending: unquote(ending), peak_bytes: 0, anon_mib_max: 900}) ==
                 {:failed, unquote(ending)}
      end
    end
  end
end
