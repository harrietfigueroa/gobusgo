defmodule Gobusgo.OneBusAway.TripPathCache.State do
  @moduledoc """
  The rules of the trip path cache's bound, over keys alone, and pure: the
  cache holds at most its bound of keys, and a key past the bound evicts the
  key put earliest. A key put again moves to the back.
  """

  alias Gobusgo.Assert

  @type key :: {String.t(), integer()}

  @type t :: %{
          order: :queue.queue(key()),
          count: non_neg_integer(),
          trip_count_max: pos_integer()
        }

  @doc "A state that holds no key, for at most `trip_count_max` keys."
  @spec new(%{trip_count_max: pos_integer()}) :: t()
  def new(%{trip_count_max: trip_count_max}) do
    Assert.condition(is_integer(trip_count_max), "trip_count_max must be an integer")

    Assert.condition(
      trip_count_max > 0,
      "trip_count_max must be positive, got: #{trip_count_max}"
    )

    %{order: :queue.new(), count: 0, trip_count_max: trip_count_max}
  end

  @doc "Returns `state` holding `key`, and the keys that leave it."
  @spec put(t(), key()) :: {t(), [key()]}
  def put(%{order: order, count: count} = state, key) do
    held = :queue.member(key, order)

    case held do
      true ->
        {%{state | order: :queue.in(key, :queue.delete(key, order))}, []}

      false ->
        added = %{state | order: :queue.in(key, order), count: count + 1}
        evict(added)
    end
  end

  @doc "Returns the count of keys `state` holds."
  @spec count(t()) :: non_neg_integer()
  def count(%{count: count}), do: count

  defp evict(%{count: count, trip_count_max: trip_count_max} = state)
       when count > trip_count_max do
    {{:value, evicted}, order} = :queue.out(state.order)
    Assert.condition(count == trip_count_max + 1, "one put passes the bound by one key at most")
    {%{state | order: order, count: count - 1}, [evicted]}
  end

  defp evict(state), do: {state, []}
end
