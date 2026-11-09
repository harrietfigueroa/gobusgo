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

  A request whose `offline_zoom_max` is a zoom, and not `nil`, also cuts
  each archive's offline extract out of the archive once it is extracted,
  in the same way, so the archive is downloaded once.

  ## Results

  `{:ok, %{archives: [%{path: ..., bytes: ...}], offline_archives: [...], manifest_path: ..., skipped: [...]}}`,
  where `offline_archives` holds the offline extracts in the same form, none
  without an offline zoom bound, and `skipped` names each agency whose
  coverage has no bounds.

  Errors:

    * `{:invalid_snapshot, snapshot}`: the snapshot is not a date written
      `YYYYMMDD`; nothing is read
    * `{:invalid_offline_zoom_max, zoom}`: the offline zoom bound is not one
      `Gobusgo.Basemap.ExtractPlan.valid_offline_zoom_max?/1` accepts;
      nothing is read
    * `{:read, reason}`: the reader's failure
    * `{:parse, reason}`: why the stored response is rejected
    * `:no_region`: no agency has coverage, so there is nothing to extract
    * `{:write, reason}`: the output directory or the manifest was not
      written
    * `{:extract, archive_name, reason}`: one extraction failed, an
      archive's or an offline extract's, with
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
          output_dir: String.t(),
          offline_zoom_max: non_neg_integer() | nil
        }
  @type archive_file :: %{path: String.t(), bytes: non_neg_integer()}
  @type extracted :: %{
          archives: [archive_file()],
          offline_archives: [archive_file()],
          manifest_path: String.t(),
          skipped: [%{agency_id: String.t(), reason: AgencyCoverage.coverage_error()}]
        }
  @type runner :: ([String.t()], pos_integer() -> :ok | {:error, term()})

  @doc "Extracts the archives of one stored agency response from one build."
  @spec run(request(), keyword()) :: {:ok, extracted()} | {:error, term()}
  def run(
        %{
          response_destination: destination,
          snapshot: snapshot,
          output_dir: output_dir,
          offline_zoom_max: offline_zoom_max
        },
        options
      )
      when is_binary(destination) and is_binary(output_dir) and is_list(options) do
    {runner, reader_options} = Keyword.pop(options, :runner, &run_tool/2)
    Assert.condition(is_function(runner, 2), "runner must be a function of two arguments")

    with :ok <- check_snapshot(snapshot),
         :ok <- check_offline_zoom_max(offline_zoom_max),
         {:ok, agencies} <- read_agencies(destination, reader_options),
         {:ok, plan} <- plan(agencies, snapshot, offline_zoom_max),
         :ok <- make_directory(output_dir),
         {:ok, extracted} <- extract_archives(plan, output_dir, runner),
         manifest = manifest(plan, extracted, destination),
         {:ok, manifest_path} <- write_manifest(manifest, output_dir) do
      {:ok,
       %{
         archives: Enum.map(extracted, & &1.archive),
         offline_archives: for(%{offline: %{} = offline} <- extracted, do: offline),
         manifest_path: manifest_path,
         skipped: plan.skipped
       }}
    end
  end

  defp check_snapshot(snapshot) do
    if ExtractPlan.valid_snapshot?(snapshot) do
      :ok
    else
      {:error, {:invalid_snapshot, snapshot}}
    end
  end

  defp check_offline_zoom_max(nil), do: :ok

  defp check_offline_zoom_max(zoom) do
    if ExtractPlan.valid_offline_zoom_max?(zoom) do
      :ok
    else
      {:error, {:invalid_offline_zoom_max, zoom}}
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

  defp plan(agencies, snapshot, offline_zoom_max) do
    case ExtractPlan.build(%{
           agencies: agencies,
           snapshot: snapshot,
           offline_zoom_max: offline_zoom_max
         }) do
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

  # The plan bounds the archives, so the loop is bounded by it. Each element
  # holds an archive and its offline extract, `nil` where the plan has none.
  defp extract_archives(%{archives: planned} = plan, output_dir, runner) do
    extracted =
      Enum.reduce_while(planned, [], fn archive, archives ->
        case extract_with_offline(%{plan: plan, archive: archive, output_dir: output_dir}, runner) do
          {:ok, extracted} -> {:cont, [extracted | archives]}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case extracted do
      {:error, _reason} = error -> error
      archives -> {:ok, Enum.reverse(archives)}
    end
  end

  defp extract_with_offline(%{archive: %{name: name, offline: offline}} = request, runner) do
    path = Path.join(request.output_dir, name)

    arguments =
      ExtractPlan.extract_arguments(%{
        plan: request.plan,
        archive: request.archive,
        output_path: path <> @partial_suffix
      })

    case extract_file(%{path: path, arguments: arguments}, runner) do
      {:ok, archive} -> extract_offline(%{archive: archive, offline: offline}, runner)
      {:error, reason} -> {:error, {:extract, name, reason}}
    end
  end

  defp extract_offline(%{archive: archive, offline: nil}, _runner),
    do: {:ok, %{archive: archive, offline: nil}}

  defp extract_offline(%{archive: %{path: archive_path} = archive, offline: offline}, runner) do
    path = Path.join(Path.dirname(archive_path), offline.name)

    arguments =
      ExtractPlan.offline_extract_arguments(%{
        offline: offline,
        archive_path: archive_path,
        output_path: path <> @partial_suffix
      })

    case extract_file(%{path: path, arguments: arguments}, runner) do
      {:ok, extracted} -> {:ok, %{archive: archive, offline: extracted}}
      {:error, reason} -> {:error, {:extract, offline.name, reason}}
    end
  end

  # Runs one extraction whose output path is the partial file beside `path`.
  defp extract_file(%{path: path, arguments: arguments}, runner) do
    partial_path = path <> @partial_suffix

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

  defp manifest(plan, extracted, destination) do
    files =
      for %{archive: archive, offline: offline} <- extracted,
          file <- [archive, offline],
          file != nil,
          do: file

    ExtractPlan.manifest(%{
      plan: plan,
      archive_bytes: Map.new(files, &{Path.basename(&1.path), &1.bytes}),
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
