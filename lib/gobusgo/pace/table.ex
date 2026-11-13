defmodule Gobusgo.Pace.Table do
  @cell_count_max_default 300_000

  @moduledoc """
  One UTC day's pace table: the seconds and meters summed in each cell of
  `Gobusgo.Pace.Learning`, held in memory. Everything here is pure.

  The table holds at most `:cell_count_max` cells,
  #{@cell_count_max_default} by default, which keeps the stored file under
  `Gobusgo.Compression.content_bytes_max/0`. At the bound a cell the table
  does not hold is counted in `dropped_count` and left out, while a cell it
  holds still takes its sums.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Pace.Learning

  @type t :: %{
          date: Date.t(),
          cells: %{Learning.key() => {number(), number()}},
          cell_count_max: pos_integer(),
          dropped_count: non_neg_integer()
        }

  @doc "The default bound of a table's cells."
  @spec cell_count_max_default() :: pos_integer()
  def cell_count_max_default, do: @cell_count_max_default

  @doc "An empty table of `input.date`."
  @spec new(%{date: Date.t(), cell_count_max: pos_integer()}) :: t()
  def new(%{date: %Date{} = date, cell_count_max: cell_count_max})
      when is_integer(cell_count_max) and cell_count_max > 0 do
    %{date: date, cells: %{}, cell_count_max: cell_count_max, dropped_count: 0}
  end

  @doc "Adds each `{key, seconds, meters}` to the table."
  @spec add(t(), [{Learning.key(), number(), number()}]) :: t()
  def add(%{} = table, additions) when is_list(additions) do
    Enum.reduce(additions, table, &add_one/2)
  end

  defp add_one({key, seconds, meters}, %{cells: cells} = table) do
    Assert.condition(seconds > 0, "seconds must be positive, got: #{seconds}")
    Assert.condition(meters >= 0, "meters must not be negative, got: #{meters}")

    case cells do
      %{^key => {held_seconds, held_meters}} ->
        %{table | cells: Map.put(cells, key, {held_seconds + seconds, held_meters + meters})}

      %{} ->
        if map_size(cells) < table.cell_count_max do
          %{table | cells: Map.put(cells, key, {seconds, meters})}
        else
          %{table | dropped_count: table.dropped_count + 1}
        end
    end
  end

  @doc "The meters every cell of the table holds, together."
  @spec meters_total(t()) :: number()
  def meters_total(%{cells: cells}) do
    Enum.sum_by(cells, fn {_key, {_seconds, meters}} -> meters end)
  end
end
