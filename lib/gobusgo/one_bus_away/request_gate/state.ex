defmodule Gobusgo.OneBusAway.RequestGate.State do
  @moduledoc """
  The rules of one request gate: who gets a permit, who waits, and what a
  rate-limited response changes. Everything here is pure: the caller supplies
  every time and the jitter, so the rules are tested with no process and no
  clock.

  A permit is granted to the first waiter when three things hold: the bucket
  has its token, fewer than `in_flight_count_max` permits are held, and the
  gate is not paused. The bucket holds at most one token and gains it
  `refill_interval_ms` after the last grant, so grants are at least that far
  apart whatever the idle time before them.

  At most `waiter_count_max` callers wait, in arrival order, each until its
  own deadline.

  A rate-limited response pauses every grant: for the time the response
  names, bounded by `retry_after_ms_max`, or else for a window that starts at
  `pause_ms_base`, doubles with each further rate-limited response up to
  `pause_ms_max`, and is jittered between half the window and the whole of
  it. When the pause ends, one permit is granted as a probe and no other
  until it is released: a completed probe reopens the gate and resets the
  window, a rate-limited one pauses again, and one that fails without a
  response lets the next waiter probe.
  """

  alias Gobusgo.Assert

  @type id :: term()
  @type time_ms :: integer()
  @type limits :: %{
          refill_interval_ms: pos_integer(),
          in_flight_count_max: pos_integer(),
          waiter_count_max: pos_integer(),
          pause_ms_base: pos_integer(),
          pause_ms_max: pos_integer(),
          retry_after_ms_max: pos_integer()
        }

  @typedoc """
  How a permit ends. `:completed`: a response that is not rate-limited
  arrived. `{:rate_limited, retry_after_ms}`: the response was rate-limited,
  with the time it names or `nil`. `:failed`: no response arrived.
  """
  @type outcome :: :completed | :failed | {:rate_limited, non_neg_integer() | nil}
  @type mode :: :open | {:paused, time_ms()} | {:probing, id()}
  @type waiter :: %{id: id(), deadline_at_ms: time_ms()}
  @type t :: %{
          limits: limits(),
          token_at_ms: time_ms() | nil,
          holder_ids: MapSet.t(id()),
          waiters: [waiter()],
          mode: mode(),
          pause_count: non_neg_integer()
        }

  @limit_keys [
    :refill_interval_ms,
    :in_flight_count_max,
    :waiter_count_max,
    :pause_ms_base,
    :pause_ms_max,
    :retry_after_ms_max
  ]

  @doc "Returns the state of an open gate with its token and nobody waiting."
  @spec new(limits()) :: t()
  def new(limits) when is_map(limits) do
    for key <- @limit_keys do
      limit = Map.fetch!(limits, key)
      Assert.condition(is_integer(limit), "#{key} must be an integer, got: #{inspect(limit)}")
      Assert.condition(limit >= 1, "#{key} must be positive, got: #{limit}")
    end

    %{
      limits: Map.take(limits, @limit_keys),
      token_at_ms: nil,
      holder_ids: MapSet.new(),
      waiters: [],
      mode: :open,
      pause_count: 0
    }
  end

  @doc "The gate's mode: open, paused until a time, or probing with one permit."
  @spec mode(t()) :: mode()
  def mode(%{mode: mode}), do: mode

  @doc "How many rate-limited responses have come since the gate was last open."
  @spec pause_count(t()) :: non_neg_integer()
  def pause_count(%{pause_count: pause_count}), do: pause_count

  @doc "How many callers wait."
  @spec waiter_count(t()) :: non_neg_integer()
  def waiter_count(%{waiters: waiters}), do: length(waiters)

  @doc """
  Adds a waiter behind those already waiting, or returns `:full` when
  `waiter_count_max` callers wait. `advance/2` grants and expires waiters.
  """
  @spec enqueue(t(), waiter()) :: {:ok, t()} | :full
  def enqueue(%{waiters: waiters} = state, %{id: id, deadline_at_ms: deadline_at_ms})
      when is_integer(deadline_at_ms) do
    Assert.condition(not MapSet.member?(state.holder_ids, id), "identifier must be new: holds")
    Assert.condition(Enum.all?(waiters, &(&1.id != id)), "identifier must be new: waits")

    if length(waiters) < state.limits.waiter_count_max do
      {:ok, %{state | waiters: waiters ++ [%{id: id, deadline_at_ms: deadline_at_ms}]}}
    else
      :full
    end
  end

  @doc """
  Brings the gate to `now_ms`: grants the first waiter a permit when the
  rules allow one, then expires every waiter left whose deadline has come.
  A waiter with no time left is granted when a permit is free at once.
  Returns the identifiers granted, at most one, and those expired.
  """
  @spec advance(t(), time_ms()) :: {t(), %{granted: [id()], expired: [id()]}}
  def advance(state, now_ms) when is_integer(now_ms) do
    {state, granted} =
      case state.waiters do
        [%{id: id} | rest] ->
          if grantable?(state, now_ms) do
            {grant(%{state | waiters: rest}, id, now_ms), [id]}
          else
            {state, []}
          end

        [] ->
          {state, []}
      end

    {expired, waiting} = Enum.split_with(state.waiters, &(&1.deadline_at_ms <= now_ms))
    state = %{state | waiters: waiting}

    in_flight_count = MapSet.size(state.holder_ids)
    Assert.condition(in_flight_count <= state.limits.in_flight_count_max, "cap must hold")
    {state, %{granted: granted, expired: Enum.map(expired, & &1.id)}}
  end

  @doc """
  The earliest time `advance/2` can grant or expire a waiter with no release
  in between, or `nil` when no waiter waits. The caller runs `advance/2`
  first, so no waiter is left that could be granted already.
  """
  @spec wake_at_ms(t()) :: time_ms() | nil
  def wake_at_ms(%{waiters: []}), do: nil

  def wake_at_ms(%{waiters: waiters} = state) do
    deadline_at_ms = waiters |> Enum.map(& &1.deadline_at_ms) |> Enum.min()

    case grant_at_ms(state) do
      nil ->
        deadline_at_ms

      :ready ->
        raise Assert.AssertionError, message: "advance/2 must run before wake_at_ms/1"

      grant_at_ms ->
        min(deadline_at_ms, grant_at_ms)
    end
  end

  @doc """
  Ends what `id` holds: its permit, with `outcome`, or its place among the
  waiters. An identifier the gate does not know changes nothing. `jitter`,
  from zero to one, places a pause inside its window.
  """
  @spec release(t(), %{id: id(), outcome: outcome(), now_ms: time_ms(), jitter: float()}) :: t()
  def release(state, %{id: id, outcome: outcome, now_ms: now_ms, jitter: jitter})
      when is_integer(now_ms) do
    Assert.condition(is_float(jitter), "jitter must be a float, got: #{inspect(jitter)}")
    Assert.condition(jitter >= 0.0, "jitter must be zero or more, got: #{jitter}")
    Assert.condition(jitter <= 1.0, "jitter must be one or less, got: #{jitter}")

    if MapSet.member?(state.holder_ids, id) do
      state = %{state | holder_ids: MapSet.delete(state.holder_ids, id)}
      finish(state, %{id: id, outcome: outcome, now_ms: now_ms, jitter: jitter})
    else
      %{state | waiters: Enum.reject(state.waiters, &(&1.id == id))}
    end
  end

  defp finish(state, %{outcome: {:rate_limited, retry_after_ms}, now_ms: now_ms, jitter: jitter}) do
    pause_count = state.pause_count + 1

    pause_ms =
      case retry_after_ms do
        nil -> backoff_ms(state.limits, %{pause_count: pause_count, jitter: jitter})
        retry_after_ms when is_integer(retry_after_ms) -> named_pause_ms(state, retry_after_ms)
      end

    %{state | mode: {:paused, now_ms + pause_ms}, pause_count: pause_count}
  end

  defp finish(%{mode: {:probing, id}} = state, %{id: id, outcome: :completed}) do
    %{state | mode: :open, pause_count: 0}
  end

  defp finish(%{mode: {:probing, id}} = state, %{id: id, outcome: :failed, now_ms: now_ms}) do
    %{state | mode: {:paused, now_ms}}
  end

  defp finish(state, %{outcome: outcome}) when outcome in [:completed, :failed], do: state

  defp named_pause_ms(state, retry_after_ms) do
    Assert.condition(retry_after_ms >= 0, "Retry-After must not be negative")
    min(retry_after_ms, state.limits.retry_after_ms_max)
  end

  # The exponent is bounded before the power is taken, so a long run of
  # rate-limited responses never computes a large integer.
  defp backoff_ms(limits, %{pause_count: pause_count, jitter: jitter}) do
    exponent_max = ceil(:math.log2(limits.pause_ms_max / limits.pause_ms_base))
    exponent = min(pause_count - 1, max(exponent_max, 0))
    window_ms = min(limits.pause_ms_base * Integer.pow(2, exponent), limits.pause_ms_max)
    half_window_ms = div(window_ms, 2)
    pause_ms = half_window_ms + round(jitter * (window_ms - half_window_ms))
    Assert.condition(pause_ms <= window_ms, "pause must fit its window")
    pause_ms
  end

  defp grantable?(state, now_ms) do
    case grant_at_ms(state) do
      nil -> false
      :ready -> true
      grant_at_ms -> grant_at_ms <= now_ms
    end
  end

  # The earliest time the rules allow a grant: `:ready` for a gate that has
  # granted nothing yet, and nil while a release has to come first, because
  # the cap is held or a probe is in flight.
  defp grant_at_ms(%{mode: {:probing, _id}}), do: nil

  defp grant_at_ms(%{holder_ids: holder_ids, limits: limits} = state) do
    if MapSet.size(holder_ids) < limits.in_flight_count_max do
      case {state.mode, state.token_at_ms} do
        {:open, nil} -> :ready
        {:open, token_at_ms} -> token_at_ms
        {{:paused, until_ms}, nil} -> until_ms
        {{:paused, until_ms}, token_at_ms} -> max(until_ms, token_at_ms)
      end
    end
  end

  defp grant(state, id, now_ms) do
    mode =
      case state.mode do
        :open -> :open
        {:paused, _until_ms} -> {:probing, id}
      end

    %{
      state
      | holder_ids: MapSet.put(state.holder_ids, id),
        token_at_ms: now_ms + state.limits.refill_interval_ms,
        mode: mode
    }
  end
end
