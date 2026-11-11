defmodule Gobusgo.Intersections.Build do
  @moduledoc """
  One build of the intersections: the osmium steps of
  `Gobusgo.Intersections.Extractor`, then `Gobusgo.Intersections.Selection`
  over the export, `Gobusgo.Intersections.Merge` over the shared nodes, and
  `Gobusgo.Intersections.Streets` over the intersections.

  `select/1` is the part after osmium, over a function that returns the
  lines of an export, and is deterministic. `run/2` takes `%{extract_path:,
  bounds:, working_dir:, service_roads:}`, where `working_dir` is a
  directory it is given or `nil` for a temporary one, and returns `{:ok,
  result}` with `source_date`, `streets`, `intersection_count`,
  `pair_count`, `selection` (the counts of `Gobusgo.Intersections.Selection`),
  `steps` (each osmium step and its time), and `select_ms`, or the
  extractor's error. The files it wrote, the export included, are removed
  before it returns, and so is a working directory it made.

  The options are the extractor's.
  """

  alias Gobusgo.Intersections.Extractor
  alias Gobusgo.Intersections.Merge
  alias Gobusgo.Intersections.Selection
  alias Gobusgo.Intersections.Streets

  @type request :: %{
          extract_path: String.t(),
          bounds: Gobusgo.Places.Bounds.t(),
          working_dir: String.t() | nil,
          service_roads: boolean()
        }

  @doc "The streets, with their crossings, that the roads of the export make inside `bounds`."
  @spec select(%{
          lines: (-> Enumerable.t(String.t())),
          bounds: Gobusgo.Places.Bounds.t(),
          service_roads: boolean()
        }) :: %{
          streets: [Streets.street()],
          intersection_count: non_neg_integer(),
          pair_count: non_neg_integer(),
          selection: map()
        }
  def select(%{lines: _lines, bounds: _bounds, service_roads: _service_roads} = request) do
    %{nodes: nodes, counts: counts} = Selection.run(request)
    %{intersections: intersections, pair_count: pair_count} = Merge.run(nodes)

    %{
      streets: Streets.group(intersections),
      intersection_count: length(intersections),
      pair_count: pair_count,
      selection: counts
    }
  end

  @doc "Builds the intersections of the extract."
  @spec run(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{working_dir: nil} = request, options) do
    working_dir =
      Path.join(System.tmp_dir!(), "gobusgo-intersections-#{System.unique_integer([:positive])}")

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
              lines: fn -> Extractor.lines(extracted.export_path) end,
              bounds: request.bounds,
              service_roads: request.service_roads
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
