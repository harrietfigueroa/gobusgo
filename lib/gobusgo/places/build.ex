defmodule Gobusgo.Places.Build do
  @moduledoc """
  One build of the places: the osmium steps of `Gobusgo.Places.Extractor`,
  then `Gobusgo.Places.Selection` over the export, then
  `Gobusgo.Places.Merge`.

  `run/2` takes `%{extract_path:, bounds:, working_dir:}`, where `working_dir`
  is a directory it is given or `nil` for a temporary one, and returns
  `{:ok, result}` with `source_date`, `places`, `selection` (the counts of
  `Gobusgo.Places.Selection`), `merged_count`, `steps` (each osmium step and
  its time), and `select_ms`, the time of selection and merging, or the
  extractor's error. The files it wrote, the export included, are removed
  before it returns, and so is a working directory it made.

  The options are the extractor's.
  """

  alias Gobusgo.Places.Extractor
  alias Gobusgo.Places.Merge
  alias Gobusgo.Places.Selection

  @type request :: %{
          extract_path: String.t(),
          bounds: Gobusgo.Places.Bounds.t(),
          working_dir: String.t() | nil
        }

  @doc "Builds the places of the extract."
  @spec run(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{working_dir: nil} = request, options) do
    working_dir =
      Path.join(System.tmp_dir!(), "gobusgo-places-#{System.unique_integer([:positive])}")

    try do
      run(%{request | working_dir: working_dir}, options)
    after
      File.rm_rf(working_dir)
    end
  end

  def run(%{working_dir: working_dir} = request, options) when is_binary(working_dir) do
    paths = Extractor.plan(request).steps |> Enum.map(& &1.output_path)

    try do
      with {:ok, extracted} <- Extractor.run(request, options) do
        {select_us, {places, selection}} =
          :timer.tc(fn ->
            Selection.run(Extractor.records(extracted.export_path), request.bounds)
          end)

        {merge_us, merged} = :timer.tc(fn -> Merge.run(places) end)

        {:ok,
         %{
           source_date: extracted.source_date,
           places: merged.places,
           selection: selection,
           merged_count: merged.merged_count,
           steps: extracted.steps,
           select_ms: div(select_us + merge_us, 1_000)
         }}
      end
    after
      Enum.each(paths, &File.rm/1)
    end
  end
end
