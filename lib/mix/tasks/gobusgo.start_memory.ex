defmodule Mix.Tasks.Gobusgo.StartMemory do
  @sample_interval_s "0.05"
  @deadline_ms 600_000
  @command_timeout_ms 60_000
  @log_line_count_max 200
  @line_bytes_max 4_096
  @failure_log_line_count 60
  @cgroup_memory_stat "/sys/fs/cgroup/memory.stat"
  @data_dir "/data"
  @responses_mount "/responses"
  @secret_byte_count 48

  @shortdoc "Fails when a start of the release image passes its memory threshold"

  @moduledoc """
  Starts the release image `--image` under production's limits, reads the
  container's anonymous memory every #{@sample_interval_s} s until the
  start has built its routing snapshots and its route and stop tile
  archive, and fails when the peak passes the threshold of
  `Gobusgo.StartMemory`, a step logs its failure, the container is killed
  for its memory or exits, or #{div(@deadline_ms, 1_000)} s pass.

      mix gobusgo.start_memory --image gobusgo:local [--responses <directory>] [--date YYYY-MM-DD] [--anon-mib-max <MiB>]

  The start reads the stored responses under `<directory>/raw/`, which are
  copied into a Docker volume of their own, so the directory is read and
  never written. Without `--responses` the task writes the synthetic
  responses of `mix gobusgo.start_memory.fixture` for `--date`, by default
  today, into a temporary directory first. A stored response is read only
  while its fetch date is one of the last days the start's rebuilds look
  back over, so a directory of older responses builds nothing and the run
  ends at the deadline.

  The container has no network, so its OneBusAway and GBFS requests fail
  at once and every byte it holds comes from the stored responses. The
  OneBusAway settings it starts with name no server that answers, so its
  sources are scheduled as production's are.

  The samples come from a shell loop inside the container, which reads the
  cgroup's `memory.stat` and so holds a little of the memory it measures,
  about a megabyte. It needs a Docker daemon whose containers use cgroup
  v2, and removes the container and the volume it made, however the run
  ends.
  """

  use Mix.Task

  alias Gobusgo.StartMemory

  @impl Mix.Task
  def run(arguments) do
    {options, []} =
      OptionParser.parse!(arguments,
        strict: [image: :string, responses: :string, date: :string, anon_mib_max: :integer]
      )

    image =
      case Keyword.fetch(options, :image) do
        {:ok, image} -> image
        :error -> Mix.raise("--image names the release image to start")
      end

    anon_mib_max = Keyword.get(options, :anon_mib_max, StartMemory.anon_mib_max())

    if anon_mib_max <= 0 do
      Mix.raise("--anon-mib-max must be positive, got: #{anon_mib_max}")
    end

    {responses, generated} = responses(options)
    run_id = "gobusgo-start-memory-#{System.unique_integer([:positive])}"

    try do
      measure(%{image: image, responses: responses, run_id: run_id, anon_mib_max: anon_mib_max})
    after
      docker(["rm", "--force", run_id])
      docker(["volume", "rm", "--force", run_id])

      if generated do
        File.rm_rf!(responses)
      end
    end
  end

  defp responses(options) do
    case Keyword.fetch(options, :responses) do
      {:ok, directory} ->
        directory = Path.expand(directory)

        if not File.dir?(Path.join(directory, "raw")) do
          Mix.raise("#{directory} holds no raw/ directory of stored responses")
        end

        {directory, false}

      :error ->
        name = "gobusgo-start-memory-#{System.unique_integer([:positive])}"
        directory = Path.join(System.tmp_dir!(), name)

        date_arguments =
          Enum.flat_map(Keyword.take(options, [:date]), fn {:date, date} -> ["--date", date] end)

        Mix.Task.run("gobusgo.start_memory.fixture", [directory | date_arguments])
        {directory, true}
    end
  end

  defp measure(%{image: image, responses: responses, run_id: run_id, anon_mib_max: anon_mib_max}) do
    docker!(["volume", "create", run_id])

    # Docker fills an empty volume with what the image holds at the mount
    # point, the owner included, so the copy and the start write as the
    # image's user.
    docker!([
      "run",
      "--rm",
      "--network",
      "none",
      "--volume",
      "#{run_id}:#{@data_dir}",
      "--volume",
      "#{responses}:#{@responses_mount}:ro",
      image,
      "cp",
      "-R",
      "#{@responses_mount}/raw",
      "#{@data_dir}/raw"
    ])

    docker!(container_arguments(%{image: image, run_id: run_id}))
    started_ms = System.monotonic_time(:millisecond)
    log_port = open_port(["logs", "--follow", run_id])

    sampler_port =
      open_port([
        "exec",
        run_id,
        "sh",
        "-c",
        "while grep '^anon ' #{@cgroup_memory_stat}; do sleep #{@sample_interval_s}; done"
      ])

    result =
      await(%{
        log_port: log_port,
        sampler_port: sampler_port,
        started_ms: started_ms,
        events: MapSet.new(),
        lines: [],
        step_lines: [],
        peak_bytes: 0,
        peak_ms: 0,
        sample_count: 0
      })

    ending =
      case result.ending do
        :stopped -> stopped(run_id)
        ending -> ending
      end

    verdict =
      StartMemory.verdict(%{
        ending: ending,
        peak_bytes: result.peak_bytes,
        anon_mib_max: anon_mib_max
      })

    report(%{result: result, verdict: verdict, anon_mib_max: anon_mib_max})
  end

  defp container_arguments(%{image: image, run_id: run_id}) do
    secret = @secret_byte_count |> :crypto.strong_rand_bytes() |> Base.encode64()
    memory = "#{StartMemory.container_memory_mib()}m"
    cpu_count = Integer.to_string(StartMemory.container_cpu_count())

    [
      "run",
      "--detach",
      "--name",
      run_id,
      "--memory",
      memory,
      "--memory-swap",
      memory,
      "--cpus",
      cpu_count,
      "--network",
      "none",
      "--volume",
      "#{run_id}:#{@data_dir}",
      # The VM starts a scheduler per processor of the host whatever the
      # quota, and an allocator instance per scheduler, so the count is set
      # to the instance's processors.
      "--env",
      "ERL_FLAGS=+S #{cpu_count}:#{cpu_count}",
      "--env",
      "SECRET_KEY_BASE=#{secret}",
      "--env",
      "GOBUSGO_PUBLIC_HOST=localhost",
      "--env",
      "ONEBUSAWAY_BASE_URL=http://onebusaway.invalid",
      "--env",
      "ONEBUSAWAY_API_KEY=not-a-key",
      image
    ]
  end

  defp open_port(arguments) do
    Port.open({:spawn_executable, docker_executable()}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, @line_bytes_max},
      args: arguments
    ])
  end

  # Waits for the next line of either port, and ends once the steps are
  # built or failed, the sampler stops with its container, or the deadline
  # passes.
  defp await(%{log_port: log_port, sampler_port: sampler_port} = state) do
    remaining_ms = @deadline_ms - (System.monotonic_time(:millisecond) - state.started_ms)

    receive do
      {^log_port, {:data, {_end, line}}} -> state |> log_line(line) |> next()
      {^log_port, {:exit_status, _status}} -> Map.put(state, :ending, :stopped)
      {^sampler_port, {:data, {_end, line}}} -> state |> sample_line(line) |> await()
      {^sampler_port, {:exit_status, _status}} -> Map.put(state, :ending, :stopped)
    after
      max(remaining_ms, 0) -> Map.put(state, :ending, :deadline)
    end
  end

  defp next(state) do
    case StartMemory.ending(state.events) do
      :running -> await(state)
      ending -> Map.put(state, :ending, ending)
    end
  end

  defp log_line(state, line) do
    lines = Enum.take([line | state.lines], @log_line_count_max)

    case StartMemory.event(line) do
      :none ->
        %{state | lines: lines}

      event ->
        events = MapSet.put(state.events, event)
        %{state | lines: lines, events: events, step_lines: [line | state.step_lines]}
    end
  end

  defp sample_line(state, line) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.started_ms
    sample_count = state.sample_count + 1

    case StartMemory.anon_bytes(line) do
      {:ok, bytes} when bytes > state.peak_bytes ->
        %{state | peak_bytes: bytes, peak_ms: elapsed_ms, sample_count: sample_count}

      {:ok, _bytes} ->
        %{state | sample_count: sample_count}

      :error ->
        Mix.raise("#{@cgroup_memory_stat} names no anon line; the check needs cgroup v2")
    end
  end

  defp stopped(run_id) do
    {:ok, text} =
      docker(["inspect", "--format", "{{.State.OOMKilled}} {{.State.ExitCode}}", run_id])

    case String.split(String.trim(text), " ") do
      ["true", _code] -> :out_of_memory
      ["false", code] -> {:exited, String.to_integer(code)}
    end
  end

  defp report(%{result: result, verdict: verdict, anon_mib_max: anon_mib_max}) do
    seconds = Float.round(result.peak_ms / 1_000, 1)
    peak = "#{StartMemory.mib(result.peak_bytes)} MiB at #{seconds} s"
    summary = "peak #{peak}, #{result.sample_count} samples, at most #{anon_mib_max} MiB"
    shell = Mix.shell()

    for line <- Enum.reverse(result.step_lines) do
      shell.info(line)
    end

    case verdict do
      :passed ->
        shell.info("Start memory passed: #{summary}")

      {:failed, reason} ->
        lines = result.lines |> Enum.take(@failure_log_line_count) |> Enum.reverse()

        for line <- lines do
          shell.info(line)
        end

        Mix.raise("Start memory failed, #{inspect(reason)}: #{summary}")
    end
  end

  defp docker!(arguments) do
    case docker(arguments) do
      {:ok, _output} ->
        :ok

      {:error, output} ->
        Mix.raise("docker #{Enum.join(Enum.take(arguments, 2), " ")} failed: #{output}")
    end
  end

  defp docker(arguments) do
    executable = docker_executable()
    task = Task.async(fn -> System.cmd(executable, arguments, stderr_to_stdout: true) end)

    case Task.yield(task, @command_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> {:error, output}
      nil -> {:error, "no answer within #{@command_timeout_ms} ms"}
    end
  end

  defp docker_executable do
    case System.find_executable("docker") do
      nil -> Mix.raise("docker is not on the PATH")
      executable -> executable
    end
  end
end
