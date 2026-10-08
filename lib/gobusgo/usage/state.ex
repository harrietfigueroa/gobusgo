defmodule Gobusgo.Usage.State do
  @moduledoc """
  The rules of usage recording: which connections are open, and the records
  of the ones that have ended and wait to be written. Everything here is
  pure.

  A holder is any term that stands for one connection; the process that owns
  this state uses the page's pid. `open/2` opens a connection, `put_filter/2`
  replaces the filter an open connection shows, and `close/2` turns an open
  connection into a record of `Gobusgo.Usage.Records`, with the time between
  the two as its duration.

  The state holds no clock: opening and closing take the time they happen
  at, in milliseconds on a clock that never goes back.

  The state holds at most `open_count_max` open connections and
  `closed_count_max` records. A connection opened beyond the first bound is
  refused, a connection that closes beyond the second leaves no record, and
  each is counted until `take_dropped/1` reads the counts.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Usage.Records

  @type holder :: term()

  @type settings :: %{open_count_max: pos_integer(), closed_count_max: pos_integer()}

  @type opening :: %{
          holder: holder(),
          connection: Records.connection(),
          connected_at: DateTime.t(),
          now_ms: integer()
        }

  @type dropped :: %{open_count: non_neg_integer(), closed_count: non_neg_integer()}

  @opaque t :: %{
            settings: settings(),
            open: %{holder() => map()},
            closed: [Records.t()],
            closed_count: non_neg_integer(),
            dropped: dropped()
          }

  @doc "A state with no connection and no record."
  @spec new(settings()) :: t()
  def new(%{open_count_max: open_count_max, closed_count_max: closed_count_max} = settings)
      when is_integer(open_count_max) and is_integer(closed_count_max) do
    Assert.condition(open_count_max >= 1, "open_count_max must be positive")
    Assert.condition(closed_count_max >= 1, "closed_count_max must be positive")

    %{
      settings: settings,
      open: %{},
      closed: [],
      closed_count: 0,
      dropped: %{open_count: 0, closed_count: 0}
    }
  end

  @doc """
  Opens the connection of `holder`. A holder with an open connection keeps
  the one it has.
  """
  @spec open(t(), opening()) :: {t(), :opened | :already_open | :open_count_exceeded}
  def open(%{open: open, settings: %{open_count_max: open_count_max}} = state, %{
        holder: holder,
        connection: connection,
        connected_at: %DateTime{} = connected_at,
        now_ms: now_ms
      })
      when is_map(connection) and is_integer(now_ms) do
    cond do
      is_map_key(open, holder) ->
        {state, :already_open}

      map_size(open) >= open_count_max ->
        {update_in(state.dropped.open_count, &(&1 + 1)), :open_count_exceeded}

      true ->
        opened = %{
          connection: connection,
          filter: %{},
          connected_at: connected_at,
          opened_ms: now_ms
        }

        {%{state | open: Map.put(open, holder, opened)}, :opened}
    end
  end

  @doc "Whether `holder` has an open connection."
  @spec open?(t(), holder()) :: boolean()
  def open?(%{open: open}, holder), do: is_map_key(open, holder)

  @doc "Replaces the filter the open connection of `holder` shows. No connection, no change."
  @spec put_filter(t(), %{holder: holder(), filter: Records.filter()}) :: t()
  def put_filter(%{open: open} = state, %{holder: holder, filter: filter}) when is_map(filter) do
    case open do
      %{^holder => opened} -> %{state | open: Map.put(open, holder, %{opened | filter: filter})}
      %{} -> state
    end
  end

  @doc "Closes the connection of `holder` at `now_ms`. No connection, no change."
  @spec close(t(), %{holder: holder(), now_ms: integer()}) :: t()
  def close(%{open: open} = state, %{holder: holder, now_ms: now_ms}) when is_integer(now_ms) do
    case Map.pop(open, holder) do
      {nil, _open} -> state
      {opened, open} -> put_closed(%{state | open: open}, opened, now_ms)
    end
  end

  defp put_closed(%{settings: %{closed_count_max: closed_count_max}} = state, opened, now_ms) do
    case state.closed_count < closed_count_max do
      true ->
        record =
          Records.build(%{
            connection: opened.connection,
            filter: opened.filter,
            connected_at: opened.connected_at,
            duration_ms: now_ms - opened.opened_ms
          })

        %{state | closed: [record | state.closed], closed_count: state.closed_count + 1}

      false ->
        update_in(state.dropped.closed_count, &(&1 + 1))
    end
  end

  @doc "The first `count` records that wait to be written, the earliest closed first."
  @spec closed(t(), pos_integer()) :: [Records.t()]
  def closed(%{closed: closed}, count) when is_integer(count) and count >= 1 do
    closed |> Enum.reverse() |> Enum.take(count)
  end

  @doc "How many records wait to be written."
  @spec closed_count(t()) :: non_neg_integer()
  def closed_count(%{closed_count: closed_count}), do: closed_count

  @doc "Forgets the `count` records closed earliest, which `closed/2` returned."
  @spec drop_closed(t(), non_neg_integer()) :: t()
  def drop_closed(%{closed: closed, closed_count: closed_count} = state, count)
      when is_integer(count) do
    Assert.condition(count >= 0, "count must be non-negative, got: #{count}")

    Assert.condition(
      count <= closed_count,
      "count must be at most #{closed_count}, got: #{count}"
    )

    %{state | closed: Enum.take(closed, closed_count - count), closed_count: closed_count - count}
  end

  @doc "The counts of what the bounds dropped since the last call, and the state with none."
  @spec take_dropped(t()) :: {dropped(), t()}
  def take_dropped(%{dropped: dropped} = state) do
    {dropped, %{state | dropped: %{open_count: 0, closed_count: 0}}}
  end
end
