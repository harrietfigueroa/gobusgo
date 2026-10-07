defmodule Gobusgo.OneBusAway.OpenStops.State do
  @moduledoc """
  The rules of the open stops: which stops are open, and who has each open.
  Everything here is pure.

  An opener is any term that stands for whoever has a stop open; the process
  that owns this state uses the opener's pid. A stop is open while at least
  one opener has it open. An opener that opens a stop it has open already
  changes nothing.

  At most `stop_count_max` stops are open, and one opener has at most
  `opener_stop_count_max` stops open. An opening beyond either bound is
  refused and changes nothing.
  """

  alias Gobusgo.Assert

  @type opener :: term()

  @type bounds :: %{stop_count_max: pos_integer(), opener_stop_count_max: pos_integer()}

  @type t :: %{
          bounds: bounds(),
          openers_by_stop: %{String.t() => MapSet.t(opener())},
          stops_by_opener: %{opener() => MapSet.t(String.t())}
        }

  @type opening :: %{opener: opener(), stop_id: String.t()}

  @typedoc """
    * `:opened` — the opener now has the stop open.
    * `:already_open` — the opener had the stop open.
    * `:stop_count_exceeded` — as many stops are open as the bound allows,
      and this stop is not among them.
    * `:opener_stop_count_exceeded` — the opener has as many stops open as
      the bound allows.
  """
  @type open_outcome ::
          :opened | :already_open | :stop_count_exceeded | :opener_stop_count_exceeded

  @doc "No stop open, within `bounds`."
  @spec new(bounds()) :: t()
  def new(%{stop_count_max: stop_count_max, opener_stop_count_max: opener_stop_count_max})
      when is_integer(stop_count_max) and is_integer(opener_stop_count_max) do
    Assert.condition(stop_count_max >= 1, "stop_count_max must be positive")
    Assert.condition(opener_stop_count_max >= 1, "opener_stop_count_max must be positive")

    %{
      bounds: %{stop_count_max: stop_count_max, opener_stop_count_max: opener_stop_count_max},
      openers_by_stop: %{},
      stops_by_opener: %{}
    }
  end

  @doc "Opens a stop for an opener and says what became of the opening."
  @spec open(t(), opening()) :: {t(), open_outcome()}
  def open(%{bounds: bounds} = state, %{opener: opener, stop_id: stop_id})
      when is_binary(stop_id) do
    opener_stops = Map.get(state.stops_by_opener, opener, MapSet.new())

    cond do
      MapSet.member?(opener_stops, stop_id) ->
        {state, :already_open}

      MapSet.size(opener_stops) >= bounds.opener_stop_count_max ->
        {state, :opener_stop_count_exceeded}

      not is_map_key(state.openers_by_stop, stop_id) and
          map_size(state.openers_by_stop) >= bounds.stop_count_max ->
        {state, :stop_count_exceeded}

      true ->
        stop_openers = Map.get(state.openers_by_stop, stop_id, MapSet.new())

        state = %{
          state
          | openers_by_stop:
              Map.put(state.openers_by_stop, stop_id, MapSet.put(stop_openers, opener)),
            stops_by_opener:
              Map.put(state.stops_by_opener, opener, MapSet.put(opener_stops, stop_id))
        }

        {state, :opened}
    end
  end

  @doc "Closes a stop for an opener. Closing a stop the opener has not open changes nothing."
  @spec close(t(), opening()) :: t()
  def close(state, %{opener: opener, stop_id: stop_id}) when is_binary(stop_id) do
    %{
      state
      | openers_by_stop: remove(state.openers_by_stop, stop_id, opener),
        stops_by_opener: remove(state.stops_by_opener, opener, stop_id)
    }
  end

  @doc "Closes every stop an opener has open."
  @spec close_all(t(), opener()) :: t()
  def close_all(state, opener) do
    state.stops_by_opener
    |> Map.get(opener, MapSet.new())
    |> Enum.reduce(state, &close(&2, %{opener: opener, stop_id: &1}))
  end

  @doc "The stops that are open, sorted."
  @spec stop_ids(t()) :: [String.t()]
  def stop_ids(%{openers_by_stop: openers_by_stop}) do
    openers_by_stop |> Map.keys() |> Enum.sort()
  end

  @doc "Whether an opener has at least one stop open."
  @spec opener?(t(), opener()) :: boolean()
  def opener?(%{stops_by_opener: stops_by_opener}, opener),
    do: is_map_key(stops_by_opener, opener)

  # Takes `member` out of the set under `key`, and the key with it once its
  # set is empty, so both maps hold only what is open.
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
