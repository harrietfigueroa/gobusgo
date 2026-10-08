defmodule Gobusgo.OneBusAway.RouteSchedule do
  @day_minutes 1_440
  @minute_seconds 60

  @moduledoc """
  When the route data of one identifier, an agency's routes or a route's
  paths, is due for a fetch. Everything here is pure.

  Each identifier has a slot: one minute of the UTC day, the hash of the
  identifier modulo #{@day_minutes}. The slots spread the identifiers over
  the day, so the refresh of a few hundred of them is a few requests an
  hour. `:erlang.phash2/2` gives the same value on every machine and
  release, so an identifier keeps its slot.

  An identifier is due when it has no fetch, or when its last fetch was made
  before the latest time its slot came. A fetch made at or after that time
  holds until the slot comes again, a day later.
  """

  @doc "The minutes from one coming of a slot to the next, which is how often an identifier is due."
  @spec period_minutes() :: pos_integer()
  def period_minutes, do: @day_minutes

  @doc "The slot of `id`: a minute of the UTC day, from 0 to #{@day_minutes - 1}."
  @spec slot_minute(String.t()) :: 0..1439
  def slot_minute(id) when is_binary(id), do: :erlang.phash2(id, @day_minutes)

  @doc "The latest time the slot of `id` came, at `now` or before it."
  @spec slot_at(String.t(), DateTime.t()) :: DateTime.t()
  def slot_at(id, %DateTime{time_zone: "Etc/UTC"} = now) when is_binary(id) do
    slot_seconds = slot_minute(id) * @minute_seconds

    today =
      now
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(slot_seconds, :second)

    if DateTime.after?(today, now) do
      DateTime.add(today, -1, :day)
    else
      today
    end
  end

  @doc """
  Whether `id`, last fetched at `fetched_at`, is due at `now`. `fetched_at`
  is `nil` for an identifier that has no fetch.
  """
  @spec due?(%{id: String.t(), fetched_at: DateTime.t() | nil, now: DateTime.t()}) :: boolean()
  def due?(%{id: id, fetched_at: nil, now: %DateTime{}}) when is_binary(id), do: true

  def due?(%{id: id, fetched_at: %DateTime{} = fetched_at, now: %DateTime{} = now})
      when is_binary(id) do
    DateTime.before?(fetched_at, slot_at(id, now))
  end
end
