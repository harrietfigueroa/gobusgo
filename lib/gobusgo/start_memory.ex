defmodule Gobusgo.StartMemory do
  @container_memory_mib 1536
  @container_cpu_count 2
  # A start of the synthetic fixture peaked at 415 to 450 MiB in five runs
  # with the segment cache off, and at 916 to 1,019 MiB in three with the
  # VM's default cache (GOB-283). With the default cache and the snapshot
  # build reading one schedule at a time, it peaked at 513 to 535 MiB in
  # six (GOB-279).
  @anon_mib_max 600
  @bytes_per_mib 1024 * 1024

  @moduledoc """
  The rules of the start-memory check, which runs the release image under
  production's limits, #{@container_memory_mib} MiB of memory and
  #{@container_cpu_count} CPUs, and reads the container's memory until the
  start's routing snapshots and tile archive are built. Everything here is
  pure: it reads text the check hands it and decides from values.

  The check reads the cgroup's `anon`, the memory no file backs, from
  `memory.stat`. The page cache of the files the start reads and writes is
  left out, since the kernel reclaims it before it kills the container. The
  BEAM's own figures are left out too: its allocators keep freed segments
  resident, which `:erlang.memory/0` does not count (GOB-278).

  The check passes when every start step it waits for logged its success
  and the peak stayed at or under #{@anon_mib_max} MiB.
  """

  alias Gobusgo.Assert

  @typedoc "A start step's outcome, as one log line names it."
  @type event :: :snapshots_built | :snapshots_failed | :tiles_built | :tiles_failed

  @typedoc """
  How a run of the check ended: with every step built, with a step that
  logged its failure, with the container killed for its memory or exited on
  its own, or at the deadline.
  """
  @type ending ::
          :built
          | {:step_failed, :snapshots_failed | :tiles_failed}
          | :out_of_memory
          | {:exited, integer()}
          | :deadline

  @type verdict :: :passed | {:failed, ending() | {:peak_exceeded, pos_integer()}}

  # Each line is the message of a log call of the application, which the
  # default formatter writes after the level.
  @event_messages [
    {"Routing snapshots built", :snapshots_built},
    {"Routing snapshots not built", :snapshots_failed},
    {"Routing snapshot build killed", :snapshots_failed},
    {"Route stop tiles built", :tiles_built},
    {"Route stop tiles not built", :tiles_failed}
  ]

  @doc "The container's memory limit in MiB, production's hard limit."
  @spec container_memory_mib() :: pos_integer()
  def container_memory_mib, do: @container_memory_mib

  @doc "The container's CPUs, those of production's instance."
  @spec container_cpu_count() :: pos_integer()
  def container_cpu_count, do: @container_cpu_count

  @doc "The highest anonymous memory in MiB the check passes."
  @spec anon_mib_max() :: pos_integer()
  def anon_mib_max, do: @anon_mib_max

  @doc "The successes a run waits for before it ends."
  @spec awaited() :: MapSet.t(event())
  def awaited, do: MapSet.new([:snapshots_built, :tiles_built])

  @doc """
  The anonymous memory in bytes that `text`, the content of a cgroup v2
  `memory.stat`, names on its `anon` line, or `:error` for text with no such
  line.
  """
  @spec anon_bytes(String.t()) :: {:ok, non_neg_integer()} | :error
  def anon_bytes(text) when is_binary(text) do
    found =
      text
      |> String.split("\n")
      |> Enum.find_value(:error, fn line ->
        case String.split(line, " ") do
          ["anon", value] -> parse_bytes(value)
          _other -> nil
        end
      end)

    case found do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :error
    end
  end

  defp parse_bytes(value) do
    case Integer.parse(value) do
      {bytes, ""} when bytes >= 0 -> {:ok, bytes}
      _other -> :error
    end
  end

  @doc "The start step outcome `line`, one line of the container's log, names, or `:none`."
  @spec event(String.t()) :: event() | :none
  def event(line) when is_binary(line) do
    Enum.find_value(@event_messages, :none, fn {message, event} ->
      if String.contains?(line, "] " <> message), do: event
    end)
  end

  @doc """
  The ending `events`, the step outcomes logged so far, amount to, or
  `:running` while a step is still awaited and none failed.
  """
  @spec ending(MapSet.t(event())) :: ending() | :running
  def ending(%MapSet{} = events) do
    failed = Enum.find([:snapshots_failed, :tiles_failed], &MapSet.member?(events, &1))
    built = MapSet.subset?(awaited(), events)

    cond do
      failed != nil -> {:step_failed, failed}
      built -> :built
      true -> :running
    end
  end

  @doc """
  Whether a run that ended with `ending` and a peak of `peak_bytes` of
  anonymous memory passes under a limit of `anon_mib_max`.
  """
  @spec verdict(%{ending: ending(), peak_bytes: non_neg_integer(), anon_mib_max: pos_integer()}) ::
          verdict()
  def verdict(%{ending: ending, peak_bytes: peak_bytes, anon_mib_max: anon_mib_max}) do
    Assert.condition(is_integer(peak_bytes), "peak_bytes must be an integer")
    Assert.condition(is_integer(anon_mib_max), "anon_mib_max must be an integer")
    Assert.condition(anon_mib_max > 0, "anon_mib_max must be positive, got: #{anon_mib_max}")
    peak_mib = mib(peak_bytes)

    case ending do
      :built when peak_mib <= anon_mib_max -> :passed
      :built -> {:failed, {:peak_exceeded, peak_mib}}
      other -> {:failed, other}
    end
  end

  @doc "`bytes` in whole MiB, rounded up, so a peak just past a limit reads past it."
  @spec mib(non_neg_integer()) :: non_neg_integer()
  def mib(bytes) when is_integer(bytes) and bytes >= 0 do
    div(bytes + @bytes_per_mib - 1, @bytes_per_mib)
  end
end
