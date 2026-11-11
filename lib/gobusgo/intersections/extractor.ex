defmodule Gobusgo.Intersections.Extractor do
  @executable "osmium"
  @fileinfo_deadline_ms 60_000
  @step_deadline_ms 600_000
  @chunk_bytes 1_048_576
  @source_date_pattern ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @moduledoc """
  Reduces an OpenStreetMap extract to the named roads the intersections are
  made of, by running `#{@executable}` once per step through
  `Gobusgo.Command`.

  `plan/1` is the steps as argument lists, and is pure. `run/2` runs them in
  a working directory, each with a deadline of #{@step_deadline_ms} ms, after
  reading the extract's source date:

    1. `fileinfo` reads `header.option.osmosis_replication_timestamp`, which
       must be a UTC date and time.
    2. `tags-filter` keeps the ways of the `highway` classes of
       `Gobusgo.Intersections.Classification`, with the nodes they list.
    3. `tags-filter w/name` keeps the ways that have a name.
    4. `extract -s complete_ways -b <west,south,east,north>` cuts the
       bounds, keeping every way that has a node inside whole.
    5. `cat -f opl,add_metadata=false` writes the ways and nodes as text
       lines, which `Gobusgo.Intersections.Selection` reads.

  The roads are filtered before the cut, so the cut reads the roads and not
  the whole state. `run/2` returns `{:ok, %{source_date:, export_path:,
  intermediate_paths:, steps: [%{name:, duration_ms:}]}}`, where
  `intermediate_paths` are the files of steps 2 to 4, which the caller
  removes with the export once it has read it. Errors: `:executable_missing`,
  `:source_date_missing`, `{:invalid_source_date, text}`, and `{:step, name,
  reason}` with `Gobusgo.Command`'s error or `:output_missing`.

  ## Options

  `:executable` is the path of osmium, by default the one on the path.
  """

  alias Gobusgo.Command
  alias Gobusgo.Intersections.Classification
  alias Gobusgo.Places.Bounds

  @type request :: %{
          extract_path: String.t(),
          bounds: Bounds.t(),
          working_dir: String.t(),
          service_roads: boolean()
        }
  @type step :: %{name: atom(), arguments: [String.t()], output_path: String.t()}
  @type run_error ::
          :executable_missing
          | :source_date_missing
          | {:invalid_source_date, String.t()}
          | {:step, atom(), Command.error() | :output_missing}

  @doc "The four steps that follow `fileinfo`, as osmium arguments."
  @spec plan(request()) :: %{steps: [step(), ...]}
  def plan(%{
        extract_path: extract_path,
        bounds: bounds,
        working_dir: working_dir,
        service_roads: service_roads
      }) do
    roads = Path.join(working_dir, "roads.osm.pbf")
    named = Path.join(working_dir, "named.osm.pbf")
    cut = Path.join(working_dir, "cut.osm.pbf")
    export = Path.join(working_dir, "roads.opl")
    box = Enum.join([bounds.west, bounds.south, bounds.east, bounds.north], ",")

    steps = [
      %{
        name: :roads,
        arguments: [
          "tags-filter",
          extract_path,
          Classification.tag_filter(service_roads),
          "-o",
          roads,
          "--overwrite"
        ],
        output_path: roads
      },
      %{
        name: :names,
        arguments: ["tags-filter", roads, "w/name", "-o", named, "--overwrite"],
        output_path: named
      },
      %{
        name: :extract,
        arguments: ["extract", "-s", "complete_ways", "-b", box, named, "-o", cut, "--overwrite"],
        output_path: cut
      },
      %{
        name: :export,
        arguments: ["cat", cut, "-f", "opl,add_metadata=false", "-o", export, "--overwrite"],
        output_path: export
      }
    ]

    %{steps: steps}
  end

  @doc "The lines of an export file, lazily, read #{@chunk_bytes} bytes at a time."
  @spec lines(String.t()) :: Enumerable.t(String.t())
  def lines(path) when is_binary(path) do
    path |> File.stream!(@chunk_bytes) |> split_lines()
  end

  @doc "The lines of a stream of chunks, which may cut a line anywhere, without their line ends."
  @spec split_lines(Enumerable.t(binary())) :: Enumerable.t(String.t())
  def split_lines(chunks) do
    chunks
    |> Stream.concat([:end])
    |> Stream.transform("", &split_chunk/2)
  end

  defp split_chunk(:end, ""), do: {[], ""}
  defp split_chunk(:end, pending), do: {[pending], ""}

  defp split_chunk(chunk, pending) do
    {complete, [rest]} = Enum.split(String.split(pending <> chunk, "\n"), -1)
    {complete, rest}
  end

  @doc "Runs the steps over the extract in the working directory, which it creates."
  @spec run(request(), keyword()) :: {:ok, map()} | {:error, run_error()}
  def run(%{extract_path: extract_path, working_dir: working_dir} = request, options)
      when is_list(options) do
    with {:ok, executable} <- executable(options),
         :ok <- make_directory(working_dir),
         {:ok, source_date, fileinfo_ms} <- source_date(executable, extract_path),
         {:ok, timed} <- run_steps(executable, plan(request).steps) do
      steps = [
        %{name: :fileinfo, duration_ms: fileinfo_ms}
        | Enum.map(timed, &Map.take(&1, [:name, :duration_ms]))
      ]

      {intermediates, [export]} = Enum.split(timed, -1)

      {:ok,
       %{
         source_date: source_date,
         export_path: export.output_path,
         intermediate_paths: Enum.map(intermediates, & &1.output_path),
         steps: steps
       }}
    end
  end

  defp executable(options) do
    case Keyword.get_lazy(options, :executable, fn -> System.find_executable(@executable) end) do
      nil -> {:error, :executable_missing}
      executable -> {:ok, executable}
    end
  end

  defp make_directory(working_dir) do
    case File.mkdir_p(working_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:step, :working_directory, {:file, reason}}}
    end
  end

  defp source_date(executable, extract_path) do
    arguments = ["fileinfo", "-g", "header.option.osmosis_replication_timestamp", extract_path]

    {duration_ms, result} =
      timed(fn ->
        Command.run(%{
          executable: executable,
          arguments: arguments,
          deadline_ms: @fileinfo_deadline_ms
        })
      end)

    case result do
      {:ok, output} -> check_source_date(String.trim(output), duration_ms)
      {:error, reason} -> {:error, {:step, :fileinfo, reason}}
    end
  end

  defp check_source_date("", _duration_ms), do: {:error, :source_date_missing}

  defp check_source_date(text, duration_ms) do
    if Regex.match?(@source_date_pattern, text) do
      {:ok, text, duration_ms}
    else
      {:error, {:invalid_source_date, text}}
    end
  end

  # The plan bounds the steps, so the loop is bounded by it.
  defp run_steps(executable, steps) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, done} ->
      case run_step(executable, step) do
        {:ok, timed} -> {:cont, {:ok, done ++ [timed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp run_step(executable, %{name: name, arguments: arguments, output_path: output_path}) do
    {duration_ms, result} =
      timed(fn ->
        Command.run(%{
          executable: executable,
          arguments: arguments,
          deadline_ms: @step_deadline_ms
        })
      end)

    case result do
      {:ok, _output} ->
        check_output(%{name: name, output_path: output_path, duration_ms: duration_ms})

      {:error, reason} ->
        {:error, {:step, name, reason}}
    end
  end

  defp check_output(%{name: name, output_path: output_path} = timed) do
    if File.regular?(output_path) do
      {:ok, timed}
    else
      {:error, {:step, name, :output_missing}}
    end
  end

  defp timed(function) do
    started_ms = System.monotonic_time(:millisecond)
    result = function.()
    {System.monotonic_time(:millisecond) - started_ms, result}
  end
end
