defmodule Gobusgo.Packed.Kinds do
  @moduledoc """
  The kinds of packed container: each kind's number, which the header holds,
  its name, and the file prefix of its stored files. A kind added later
  takes the next free number in its own change. The columns of a kind belong
  to the kind, not here. `test/fixtures/packed/kinds.json` holds the same
  table, which this table and the JavaScript core's are each checked
  against. Everything here is pure.
  """

  @kinds [
    %{number: 0, name: "fixture", prefix: "fixture"},
    %{number: 1, name: "trip path shard", prefix: "trip-paths"},
    %{number: 2, name: "trip path index", prefix: "trip-paths-index"},
    %{number: 3, name: "address shard", prefix: "addresses"},
    %{number: 4, name: "address index", prefix: "addresses-index"},
    %{number: 5, name: "places", prefix: "places"},
    %{number: 6, name: "intersection shard", prefix: "intersections"},
    %{number: 7, name: "intersection index", prefix: "intersections-index"}
  ]

  @typedoc "One row of the kind table."
  @type kind :: %{number: non_neg_integer(), name: String.t(), prefix: String.t()}

  @doc "Every kind, in number order."
  @spec all() :: [kind()]
  def all, do: @kinds

  @doc "Returns the kind numbered `number`, or `:unknown`."
  @spec fetch(integer()) :: {:ok, kind()} | :unknown
  def fetch(number) when is_integer(number) do
    case Enum.find(@kinds, &(&1.number == number)) do
      nil -> :unknown
      kind -> {:ok, kind}
    end
  end
end
