defmodule Gobusgo.WalkGraph.Build do
  @simplify_units 1.0

  @moduledoc """
  One build of the walk graph: the osmium steps of
  `Gobusgo.WalkGraph.Extractor`, then `Gobusgo.WalkGraph.Selection` over the
  export.

  `select/1` is the part after osmium, over a function that returns the
  lines of an export, and is deterministic. `run/2` takes `%{extract_path:,
  bounds:, working_dir:}`, where `working_dir` is a directory it is given or
  `nil` for a temporary one, and returns `{:ok, result}` with `source_date`,
  `tiles` (the pieces by tile), `selection` (the counts of
  `Gobusgo.WalkGraph.Selection`), `steps` (each osmium step and its time),
  and `select_ms`, or the extractor's error. The files it wrote, the export
  included, are removed before it returns, and so is a working directory it
  made. The options are the extractor's.
  """

  alias Gobusgo.WalkGraph.Extractor
  alias Gobusgo.WalkGraph.Selection
  alias Gobusgo.WalkGraph.Tiles

  @type request :: %{
          extract_path: String.t(),
          bounds: Gobusgo.Places.Bounds.t(),
          working_dir: String.t() | nil
        }

  @doc "The pieces of the walkable ways of the export, by tile, and the counts of what became of each line."
  @spec select(Selection.request()) :: %{
          tiles: %{Tiles.tile() => [Selection.piece()]},
          selection: map()
        }
  def select(%{lines: _lines, tile_sizes: _tile_sizes, simplify_units: _simplify_units} = request) do
    %{tiles: tiles, counts: counts} = Selection.run(request)
    %{tiles: tiles, selection: counts}
  end

  @doc "Builds the walk graph of the extract."
  @spec run(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{working_dir: nil} = request, options) do
    working_dir =
      Path.join(System.tmp_dir!(), "gobusgo-walk-graph-#{System.unique_integer([:positive])}")

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
        {select_us, selected} =
          :timer.tc(fn ->
            select(%{
              lines: fn -> Gobusgo.Intersections.Extractor.lines(extracted.export_path) end,
              tile_sizes: Tiles.sizes(),
              simplify_units: @simplify_units
            })
          end)

        {:ok,
         selected
         |> Map.put(:source_date, extracted.source_date)
         |> Map.put(:steps, extracted.steps)
         |> Map.put(:select_ms, div(select_us, 1_000))}
      end
    after
      Enum.each(paths, &File.rm/1)
    end
  end
end
