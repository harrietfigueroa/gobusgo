defmodule Gobusgo.Demand.State do
  @dataset_count_max 16

  @moduledoc """
  The rules of demand: which items of each dataset are in demand, and who
  holds each key. Everything here is pure.

  A key is `{dataset, item}`: a dataset the state was created with and a
  non-empty item of it. A holder is any term that stands for whoever holds a
  key; the process that owns this state uses the holder's pid. An item is in
  demand while at least one holder holds its key. A holder that registers a
  key it holds already changes nothing.

  The bounds count inside one dataset: each dataset has at most
  `item_count_max` items, and one holder holds at most
  `holder_item_count_max` items of one dataset. A registration beyond either
  bound is refused and changes nothing. A state has at most
  #{@dataset_count_max} datasets.

  A dataset the state was not created with is a programmer error:
  `dataset?/2` answers whether a dataset is one of them, and every other
  function raises for one that is not.
  """

  alias Gobusgo.Assert

  @type holder :: term()

  @type dataset :: atom()

  @type key :: {dataset(), item :: String.t()}

  @type bounds :: %{item_count_max: pos_integer(), holder_item_count_max: pos_integer()}

  @type settings :: %{
          datasets: [dataset(), ...],
          item_count_max: pos_integer(),
          holder_item_count_max: pos_integer()
        }

  @type holdings :: %{
          holders_by_item: %{String.t() => MapSet.t(holder())},
          items_by_holder: %{holder() => MapSet.t(String.t())}
        }

  @type t :: %{bounds: bounds(), holdings_by_dataset: %{dataset() => holdings()}}

  @type registration :: %{holder: holder(), key: key()}

  @typedoc """
    * `:registered` — the holder now holds the key.
    * `:already_registered` — the holder held the key.
    * `:item_count_exceeded` — the dataset has as many items as the bound
      allows, and this item is not among them.
    * `:holder_item_count_exceeded` — the holder holds as many items of the
      dataset as the bound allows.
  """
  @type register_outcome ::
          :registered | :already_registered | :item_count_exceeded | :holder_item_count_exceeded

  @doc "The most datasets a state has."
  @spec dataset_count_max() :: pos_integer()
  def dataset_count_max, do: @dataset_count_max

  @doc "No key held, for `datasets`, within the two bounds."
  @spec new(settings()) :: t()
  def new(%{
        datasets: datasets,
        item_count_max: item_count_max,
        holder_item_count_max: holder_item_count_max
      })
      when is_list(datasets) and is_integer(item_count_max) and is_integer(holder_item_count_max) do
    dataset_count = length(datasets)
    Assert.condition(dataset_count >= 1, "datasets must name at least one dataset")

    Assert.condition(
      dataset_count <= @dataset_count_max,
      "datasets must name at most #{@dataset_count_max} datasets, got: #{dataset_count}"
    )

    Assert.condition(Enum.all?(datasets, &is_atom/1), "datasets must be atoms")
    Assert.condition(Enum.uniq(datasets) == datasets, "datasets must name each dataset once")
    Assert.condition(item_count_max >= 1, "item_count_max must be positive")
    Assert.condition(holder_item_count_max >= 1, "holder_item_count_max must be positive")

    %{
      bounds: %{item_count_max: item_count_max, holder_item_count_max: holder_item_count_max},
      holdings_by_dataset: Map.new(datasets, &{&1, %{holders_by_item: %{}, items_by_holder: %{}}})
    }
  end

  @doc "Whether `dataset` is one the state was created with."
  @spec dataset?(t(), dataset()) :: boolean()
  def dataset?(%{holdings_by_dataset: holdings_by_dataset}, dataset) when is_atom(dataset),
    do: is_map_key(holdings_by_dataset, dataset)

  @doc "Registers a key for a holder and says what became of the registration."
  @spec register(t(), registration()) :: {t(), register_outcome()}
  def register(%{bounds: bounds} = state, %{holder: holder, key: {dataset, item}})
      when is_binary(item) do
    Assert.condition(item != "", "item must be non-empty")
    holdings = holdings(state, dataset)
    holder_items = Map.get(holdings.items_by_holder, holder, MapSet.new())

    cond do
      MapSet.member?(holder_items, item) ->
        {state, :already_registered}

      MapSet.size(holder_items) >= bounds.holder_item_count_max ->
        {state, :holder_item_count_exceeded}

      not is_map_key(holdings.holders_by_item, item) and
          map_size(holdings.holders_by_item) >= bounds.item_count_max ->
        {state, :item_count_exceeded}

      true ->
        item_holders = Map.get(holdings.holders_by_item, item, MapSet.new())

        holdings = %{
          holders_by_item:
            Map.put(holdings.holders_by_item, item, MapSet.put(item_holders, holder)),
          items_by_holder:
            Map.put(holdings.items_by_holder, holder, MapSet.put(holder_items, item))
        }

        {put_holdings(state, dataset, holdings), :registered}
    end
  end

  @doc "Releases a key for a holder. Releasing a key the holder does not hold changes nothing."
  @spec release(t(), registration()) :: t()
  def release(state, %{holder: holder, key: {dataset, item}}) when is_binary(item) do
    holdings = holdings(state, dataset)

    put_holdings(state, dataset, %{
      holders_by_item: remove(holdings.holders_by_item, item, holder),
      items_by_holder: remove(holdings.items_by_holder, holder, item)
    })
  end

  @doc "Releases every key a holder holds, in every dataset."
  @spec release_all(t(), holder()) :: t()
  def release_all(%{holdings_by_dataset: holdings_by_dataset} = state, holder) do
    Enum.reduce(holdings_by_dataset, state, fn {dataset, holdings}, state ->
      holdings.items_by_holder
      |> Map.get(holder, MapSet.new())
      |> Enum.reduce(state, &release(&2, %{holder: holder, key: {dataset, &1}}))
    end)
  end

  @doc "The items of `dataset` that at least one holder holds the key of, sorted."
  @spec items(t(), dataset()) :: [String.t()]
  def items(state, dataset) do
    state |> holdings(dataset) |> Map.fetch!(:holders_by_item) |> Map.keys() |> Enum.sort()
  end

  @doc "How many holders hold `key`."
  @spec holder_count(t(), key()) :: non_neg_integer()
  def holder_count(state, {dataset, item}) when is_binary(item) do
    state
    |> holdings(dataset)
    |> Map.fetch!(:holders_by_item)
    |> Map.get(item, MapSet.new())
    |> MapSet.size()
  end

  @doc "Whether a holder holds at least one key, in any dataset."
  @spec holder?(t(), holder()) :: boolean()
  def holder?(%{holdings_by_dataset: holdings_by_dataset}, holder) do
    Enum.any?(holdings_by_dataset, fn {_dataset, holdings} ->
      is_map_key(holdings.items_by_holder, holder)
    end)
  end

  defp holdings(state, dataset) do
    Assert.condition(
      dataset?(state, dataset),
      "dataset must be one the state was created with, got: #{inspect(dataset)}"
    )

    Map.fetch!(state.holdings_by_dataset, dataset)
  end

  defp put_holdings(state, dataset, holdings) do
    %{state | holdings_by_dataset: Map.put(state.holdings_by_dataset, dataset, holdings)}
  end

  # Takes `member` out of the set under `key`, and the key with it once its
  # set is empty, so both maps hold only what is held.
  defp remove(sets, key, member) do
    case Map.fetch(sets, key) do
      {:ok, set} ->
        set = MapSet.delete(set, member)

        case MapSet.size(set) do
          0 -> Map.delete(sets, key)
          _size -> Map.put(sets, key, set)
        end

      :error ->
        sets
    end
  end
end
