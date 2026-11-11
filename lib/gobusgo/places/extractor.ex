defmodule Gobusgo.Places.Extractor do
  @executable "osmium"
  @fileinfo_deadline_ms 60_000
  @step_deadline_ms 600_000
  @record_separator "\u001e"
  @chunk_bytes 1_048_576
  @source_date_pattern ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @moduledoc """
  Reduces an OpenStreetMap extract to the features the places file is made
  of, by running `#{@executable}` once per step through `Gobusgo.Command`.

  `plan/1` is the steps as argument lists, and is pure. `run/2` runs them in
  a working directory, each with a deadline of #{@step_deadline_ms} ms, after
  reading the extract's source date:

    1. `fileinfo` reads `header.option.osmosis_replication_timestamp`, which
       must be a UTC date and time.
    2. `extract -s smart -b <west,south,east,north>` cuts the bounds, with
       the members of the relations that reach into them.
    3. `tags-filter nwr/name` keeps what has a name.
    4. `tags-filter` on `Gobusgo.Places.Classification.tag_filters/0` keeps
       what a category can accept.
    5. `export -f geojsonseq -a type,id --geometry-types=point,polygon`
       writes one record per feature, each after a U+001E separator,
       since a tag value can hold a newline.

  `run/2` returns `{:ok, %{source_date:, export_path:, intermediate_paths:,
  steps: [%{name:, duration_ms:}]}}`, where `intermediate_paths` are the
  files of steps 2 to 4, which the caller removes with the export once it
  has read it. Errors: `:executable_missing`, `:source_date_missing`,
  `{:invalid_source_date, text}`, and `{:step, name, reason}` with
  `Gobusgo.Command`'s error or `:output_missing`.

  ## Options

  `:executable` is the path of osmium, by default the one on the path.
  """

  alias Gobusgo.Command
  alias Gobusgo.Places.Bounds
  alias Gobusgo.Places.Classification

  @type request :: %{extract_path: String.t(), bounds: Bounds.t(), working_dir: String.t()}
  @type step :: %{name: atom(), arguments: [String.t()], output_path: String.t()}
  @type run_error ::
          :executable_missing
          | :source_date_missing
          | {:invalid_source_date, String.t()}
          | {:step, atom(), Command.error() | :output_missing}

  @doc "The four steps that follow `fileinfo`, as osmium arguments."
  @spec plan(request()) :: %{steps: [step(), ...]}
  def plan(%{extract_path: extract_path, bounds: bounds, working_dir: working_dir}) do
    cut = Path.join(working_dir, "cut.osm.pbf")
    named = Path.join(working_dir, "named.osm.pbf")
    categorized = Path.join(working_dir, "categorized.osm.pbf")
    export = Path.join(working_dir, "places.geojsonseq")
    box = Enum.join([bounds.west, bounds.south, bounds.east, bounds.north], ",")

    steps = [
      %{
        name: :extract,
        arguments: ["extract", "-s", "smart", "-b", box, extract_path, "-o", cut, "--overwrite"],
        output_path: cut
      },
      %{
        name: :names,
        arguments: ["tags-filter", cut, "nwr/name", "-o", named, "--overwrite"],
        output_path: named
      },
      %{
        name: :categories,
        arguments:
          ["tags-filter", named] ++
            Classification.tag_filters() ++ ["-o", categorized, "--overwrite"],
        output_path: categorized
      },
      %{
        name: :export,
        arguments: [
          "export",
          categorized,
          "-f",
          "geojsonseq",
          "-a",
          "type,id",
          "--geometry-types=point,polygon",
          "-o",
          export,
          "--overwrite"
        ],
        output_path: export
      }
    ]

    %{steps: steps}
  end

  @doc """
  The records of an export file, as a lazy stream of the texts between U+001E
  separators, read #{@chunk_bytes} bytes at a time.
  """
  @spec records(String.t()) :: Enumerable.t(String.t())
  def records(path) when is_binary(path),
    do: path |> File.stream!(@chunk_bytes) |> split_records()

  @doc "The records of a stream of chunks, which may cut a record anywhere."
  @spec split_records(Enumerable.t(binary())) :: Enumerable.t(String.t())
  def split_records(chunks) do
    chunks
    |> Stream.concat([:end])
    |> Stream.transform("", &split_chunk/2)
  end

  defp split_chunk(:end, pending), do: {[pending], ""}

  defp split_chunk(chunk, pending) do
    {complete, [rest]} = Enum.split(String.split(pending <> chunk, @record_separator), -1)
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
