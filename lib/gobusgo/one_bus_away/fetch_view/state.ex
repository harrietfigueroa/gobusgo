defmodule Gobusgo.OneBusAway.FetchView.State do
  @moduledoc """
  The rules of a fetch view: which fetch is current for each identifier.
  Everything here is pure.

  A fetch is whole in one record, so it is current as soon as it is put. A
  fetch is ignored when it is its identifier's current one or is older than
  it, so records published again change nothing and an old fetch never
  replaces a newer one. A fetch with the same fetch time as the current one
  and another request identifier replaces it.

  At most `id_count_max` identifiers have a current fetch; the fetch of an
  identifier beyond that is ignored.

  A view made with `new_expiring/1` also drops fetches by age. `expire/2`
  takes the time it is and removes every current fetch older than
  `fetch_age_ms_max`, and from then on a fetch that old at that time is
  ignored when put, so records read again from their start do not bring
  back what has expired. A view made with `new/1` keeps every fetch.

  The state keeps the request identifier and the fetch time of each current
  fetch, which is all its rules read.

  An attempt is a fetch that was recorded. `attempt/2` keeps its time for an
  identifier whose current fetch is older than it or absent, and a fetch put
  at or after that time clears it, so `attempts/1` holds the recorded
  fetches that have not reached the view. At most `id_count_max` attempts
  are kept; the earliest leaves for one beyond that. A view whose fetches
  expire drops an attempt at the same age.
  """

  alias Gobusgo.Assert
  alias Gobusgo.RequestId

  @typedoc "What a fetch has to carry for the rules; a view holds the rest."
  @type fetch :: %{
          required(:id) => String.t(),
          required(:request_id) => RequestId.t(),
          required(:fetched_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @type header :: %{request_id: RequestId.t(), fetched_at: DateTime.t()}

  @type t :: %{
          current: %{String.t() => header()},
          attempts: %{String.t() => DateTime.t()},
          id_count_max: pos_integer(),
          fetch_age_ms_max: pos_integer() | nil,
          expired_before: DateTime.t() | nil
        }

  @typedoc """
    * `:switched` — the fetch is now its identifier's current fetch.
    * `:ignored` — the fetch changed nothing.
  """
  @type outcome :: :switched | :ignored

  @doc "A view with no current fetch, for at most `id_count_max` identifiers."
  @spec new(pos_integer()) :: t()
  def new(id_count_max) when is_integer(id_count_max) do
    Assert.condition(id_count_max >= 1, "id_count_max must be positive, got: #{id_count_max}")

    %{
      current: %{},
      attempts: %{},
      id_count_max: id_count_max,
      fetch_age_ms_max: nil,
      expired_before: nil
    }
  end

  @doc """
  A view with no current fetch, for at most `id_count_max` identifiers, whose
  fetches expire once they are older than `fetch_age_ms_max`.
  """
  @spec new_expiring(%{id_count_max: pos_integer(), fetch_age_ms_max: pos_integer()}) :: t()
  def new_expiring(%{id_count_max: id_count_max, fetch_age_ms_max: fetch_age_ms_max})
      when is_integer(fetch_age_ms_max) do
    Assert.condition(
      fetch_age_ms_max >= 1,
      "fetch_age_ms_max must be positive, got: #{fetch_age_ms_max}"
    )

    %{new(id_count_max) | fetch_age_ms_max: fetch_age_ms_max}
  end

  @doc """
  Removes every current fetch and every attempt that is older than the
  view's age bound at `now`, and returns the identifiers whose fetch was
  removed, sorted. A view that keeps every fetch removes none.
  """
  @spec expire(t(), DateTime.t()) :: {t(), [String.t()]}
  def expire(%{fetch_age_ms_max: nil} = state, %DateTime{}), do: {state, []}

  def expire(%{fetch_age_ms_max: fetch_age_ms_max, current: current} = state, %DateTime{} = now) do
    expired_before = DateTime.add(now, -fetch_age_ms_max, :millisecond)

    expired_ids =
      for {id, %{fetched_at: fetched_at}} <- current,
          DateTime.before?(fetched_at, expired_before) do
        id
      end

    attempts =
      Map.reject(state.attempts, fn {_id, attempted_at} ->
        DateTime.before?(attempted_at, expired_before)
      end)

    state = %{
      state
      | current: Map.drop(current, expired_ids),
        attempts: attempts,
        expired_before: expired_before
    }

    {state, Enum.sort(expired_ids)}
  end

  @doc """
  The request identifier and the fetch time of the current fetch of every
  identifier that has one.
  """
  @spec current(t()) :: %{String.t() => header()}
  def current(%{current: current}), do: current

  @doc """
  The time of the latest attempt of every identifier whose current fetch is
  older than that attempt or absent.
  """
  @spec attempts(t()) :: %{String.t() => DateTime.t()}
  def attempts(%{attempts: attempts}), do: attempts

  @doc """
  Notes that a fetch of `id` made at `fetched_at` was recorded. The attempt
  is kept when it is later than the identifier's current fetch and its
  earlier attempt, and changes nothing otherwise.
  """
  @spec attempt(t(), %{id: String.t(), fetched_at: DateTime.t()}) :: t()
  def attempt(%{attempts: attempts} = state, %{id: id, fetched_at: %DateTime{} = fetched_at})
      when is_binary(id) do
    if Enum.all?(known_times(state, id), &DateTime.after?(fetched_at, &1)) do
      %{state | attempts: attempts |> Map.put(id, fetched_at) |> bound(state.id_count_max)}
    else
      state
    end
  end

  @doc "Applies one fetch and says what became of it."
  @spec put(t(), fetch()) :: {t(), outcome()}
  def put(%{current: current, id_count_max: id_count_max} = state, %{id: id} = fetch)
      when is_binary(id) do
    %{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = fetch

    accepted =
      if expired?(state, fetched_at) do
        false
      else
        case Map.fetch(current, id) do
          {:ok, header} -> not superseded?(header, fetch)
          :error -> map_size(current) < id_count_max
        end
      end

    if accepted do
      header = %{request_id: request_id, fetched_at: fetched_at}
      attempts = clear_attempt(state.attempts, id, fetched_at)
      {%{state | current: Map.put(current, id, header), attempts: attempts}, :switched}
    else
      {state, :ignored}
    end
  end

  # The fetch time and the attempt time the state holds for `id`.
  defp known_times(%{current: current, attempts: attempts}, id) do
    fetch_times =
      case Map.fetch(current, id) do
        {:ok, %{fetched_at: fetched_at}} -> [fetched_at]
        :error -> []
      end

    attempt_times =
      case Map.fetch(attempts, id) do
        {:ok, attempted_at} -> [attempted_at]
        :error -> []
      end

    fetch_times ++ attempt_times
  end

  defp bound(attempts, id_count_max) do
    if map_size(attempts) <= id_count_max do
      attempts
    else
      {earliest_id, _attempted_at} =
        Enum.min_by(attempts, fn {id, attempted_at} ->
          {DateTime.to_unix(attempted_at, :microsecond), id}
        end)

      Map.delete(attempts, earliest_id)
    end
  end

  defp clear_attempt(attempts, id, fetched_at) do
    case Map.fetch(attempts, id) do
      {:ok, attempted_at} ->
        if DateTime.after?(attempted_at, fetched_at) do
          attempts
        else
          Map.delete(attempts, id)
        end

      :error ->
        attempts
    end
  end

  defp expired?(%{expired_before: nil}, _fetched_at), do: false

  defp expired?(%{expired_before: expired_before}, fetched_at) do
    DateTime.before?(fetched_at, expired_before)
  end

  defp superseded?(%{request_id: request_id}, %{request_id: request_id}), do: true

  defp superseded?(%{fetched_at: current_fetched_at}, %{fetched_at: fetched_at}) do
    DateTime.before?(fetched_at, current_fetched_at)
  end
end
