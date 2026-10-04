defmodule Gobusgo.Basemap.Extractor do
  @extract_deadline_ms 600_000
  @manifest_name "manifest.json"
  @tool "pmtiles"

  @moduledoc """
  Cuts the regional basemap archives that a stored agency response needs out
  of a Protomaps build, into a directory.

  `run/2` reads the stored response through `Gobusgo.Reader`, plans the
  archives with `Gobusgo.Basemap.ExtractPlan`, and runs the `#{@tool}`
  command once per archive, one after another, each with a deadline of
  #{@extract_deadline_ms} milliseconds. An archive is written beside its
  final name and renamed once the command succeeds, so a file under an
  archive's name is always a whole archive, and an archive of an earlier run
  with the same name is replaced. `#{@manifest_name}`, written last in
  compact JSON with sorted keys, records the run.

  ## Results

  `{:ok, %{archives: [%{path: ..., bytes: ...}], manifest_path: ..., skipped: [...]}}`,
  where `skipped` names each agency whose coverage has no bounds.

  Errors:

    * `{:invalid_snapshot, snapshot}`: the snapshot is not a date written
      `YYYYMMDD`; nothing is read
    * `{:read, reason}`: the reader's failure
    * `{:parse, reason}`: why the stored response is rejected
    * `:no_region`: no agency has coverage, so there is nothing to extract
    * `{:write, reason}`: the output directory or the manifest was not
      written
    * `{:extract, archive_name, reason}`: one extraction failed, with
      `:tool_missing` when no `#{@tool}` executable is found,
      `{:exit_status, status}`, `:deadline_exceeded`, `:archive_missing` when
      the command wrote no file, or a file reason. Archives extracted before
      it stay, and no manifest is written

  ## Options

  `:runner` is a function of the command's arguments and a deadline in
  milliseconds that returns `:ok` or `{:error, reason}`; it replaces the
  `#{@tool}` executable. Every other option goes to the reader.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Basemap.ExtractPlan
  alias Gobusgo.CanonicalJson
  alias Gobusgo.OneBusAway.AgencyCoverage
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Reader

  @partial_suffix ".partial"

  @type request :: %{
          response_destination: String.t(),
          snapshot: String.t(),
          output_dir: String.t()
        }
  @type extracted :: %{
          archives: [%{path: String.t(), bytes: non_neg_integer()}],
          manifest_path: String.t(),
          skipped: [%{agency_id: String.t(), reason: AgencyCoverage.coverage_error()}]
        }
  @type runner :: ([String.t()], pos_integer() -> :ok | {:error, term()})

  @doc "Extracts the archives of one stored agency response from one build."
  @spec run(request(), keyword()) :: {:ok, extracted()} | {:error, term()}
  def run(
        %{response_destination: destination, snapshot: snapshot, output_dir: output_dir},
        options
      )
      when is_binary(destination) and is_binary(output_dir) and is_list(options) do
    {runner, reader_options} = Keyword.pop(options, :runner, &run_tool/2)
    Assert.condition(is_function(runner, 2), "runner must be a function of two arguments")

    with :ok <- check_snapshot(snapshot),
         {:ok, agencies} <- read_agencies(destination, reader_options),
         {:ok, plan} <- plan(agencies, snapshot),
         :ok <- make_directory(output_dir),
         {:ok, archives} <- extract_archives(plan, output_dir, runner),
         manifest = manifest(plan, archives, destination),
         {:ok, manifest_path} <- write_manifest(manifest, output_dir) do
      {:ok, %{archives: archives, manifest_path: manifest_path, skipped: plan.skipped}}
    end
  end

  defp check_snapshot(snapshot) do
    if ExtractPlan.valid_snapshot?(snapshot) do
      :ok
    else
      {:error, {:invalid_snapshot, snapshot}}
    end
  end

  defp read_agencies(destination, reader_options) do
    case Reader.read(destination, reader_options) do
      {:ok, content} ->
        case RawAgencyResponse.parse(%{destination: destination, content: content}) do
          {:ok, %{agencies: agencies}} -> {:ok, agencies}
          {:error, reason} -> {:error, {:parse, reason}}
        end

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  defp plan(agencies, snapshot) do
    case ExtractPlan.build(%{agencies: agencies, snapshot: snapshot}) do
      %{archives: []} -> {:error, :no_region}
      plan -> {:ok, plan}
    end
  end

  defp make_directory(output_dir) do
    case File.mkdir_p(output_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  # The plan bounds the archives, so the loop is bounded by it.
  defp extract_archives(%{archives: planned} = plan, output_dir, runner) do
    extracted =
      Enum.reduce_while(planned, [], fn %{name: name} = archive, archives ->
        case extract_archive(%{plan: plan, archive: archive, output_dir: output_dir}, runner) do
          {:ok, extracted} -> {:cont, [extracted | archives]}
          {:error, reason} -> {:halt, {:error, {:extract, name, reason}}}
        end
      end)

    case extracted do
      {:error, _reason} = error -> error
      archives -> {:ok, Enum.reverse(archives)}
    end
  end

  defp extract_archive(
         %{plan: plan, archive: %{name: name} = archive, output_dir: output_dir},
         runner
       ) do
    path = Path.join(output_dir, name)
    partial_path = path <> @partial_suffix

    arguments =
      ExtractPlan.extract_arguments(%{plan: plan, archive: archive, output_path: partial_path})

    with :ok <- runner.(arguments, @extract_deadline_ms),
         {:ok, bytes} <- archive_bytes(partial_path),
         :ok <- File.rename(partial_path, path) do
      {:ok, %{path: path, bytes: bytes}}
    else
      {:error, reason} ->
        # The partial file is absent when the command wrote nothing, so the
        # outcome of the removal carries no information.
        _removed = File.rm(partial_path)
        {:error, reason}
    end
  end

  defp archive_bytes(path) do
    case File.stat(path) do
      {:ok, %{size: bytes}} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :archive_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp manifest(plan, archives, destination) do
    ExtractPlan.manifest(%{
      plan: plan,
      archive_bytes: Map.new(archives, &{Path.basename(&1.path), &1.bytes}),
      response_destination: destination
    })
  end

  defp write_manifest(manifest, output_dir) do
    path = Path.join(output_dir, @manifest_name)

    case File.write(path, CanonicalJson.encode(manifest)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp run_tool(arguments, deadline_ms) do
    case System.find_executable(@tool) do
      nil -> {:error, :tool_missing}
      executable -> run_executable(executable, arguments, deadline_ms)
    end
  end

  # The command runs in a task so that the deadline ends the wait. Killing
  # the task closes the port, which closes the command's input and output.
  defp run_executable(executable, arguments, deadline_ms) do
    task =
      Task.async(fn ->
        System.cmd(executable, arguments, stderr_to_stdout: true, into: IO.stream(:stdio, :line))
      end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, status}} -> {:error, {:exit_status, status}}
      nil -> {:error, :deadline_exceeded}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end
end
