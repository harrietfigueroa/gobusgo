defmodule Gobusgo.OneBusAway.AgencyView.State do
  @held_fetch_count_max 8
  @agency_count_max 1_000

  @moduledoc """
  The rules of the agency view: which fetch is current, and which records
  are held until their fetch is complete. Everything here is pure.

  A fetch is complete when its manifest and every agency the manifest names
  have been put. The view switches to a complete fetch in one step, so the
  current fetch always holds exactly the agencies its manifest names.

  A record is ignored when its fetch is the current one or is older than
  the current one, so records published again change nothing and an old
  fetch never replaces a newer one. A fetch with the same fetch time as the
  current one and another request identifier replaces it.

  At most #{@held_fetch_count_max} incomplete fetches are held, the oldest
  forgotten first, each with at most #{@agency_count_max} agencies. A switch
  forgets every held fetch older than the new current one.
  """

  alias Gobusgo.OneBusAway.AgencyBatch.Records
  alias Gobusgo.RequestId

  @type agency :: %{String.t() => term()}

  @type current :: %{
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          agency_ids: [String.t()],
          agencies: %{String.t() => agency()}
        }

  @type held :: %{
          fetched_at: DateTime.t(),
          agencies: %{String.t() => agency()},
          agency_ids: [String.t()] | nil
        }

  @type t :: %{current: current() | nil, held: %{RequestId.t() => held()}}

  @type outcome :: :held | :switched | :ignored

  @doc "A view with no current fetch and nothing held."
  @spec new() :: t()
  def new, do: %{current: nil, held: %{}}

  @doc "Incomplete fetches held at once."
  @spec held_fetch_count_max() :: pos_integer()
  def held_fetch_count_max, do: @held_fetch_count_max

  @doc "The current fetch, or `nil` before any fetch is complete."
  @spec current(t()) :: current() | nil
  def current(%{current: current}), do: current

  @doc "Applies one decoded record and says what became of it."
  @spec put(t(), Records.decoded()) :: {t(), outcome()}
  def put(%{current: current, held: held} = state, {kind, %{request_id: request_id} = record}) do
    fetch =
      Map.get(held, request_id, %{fetched_at: record.fetched_at, agencies: %{}, agency_ids: nil})

    if accepted?(current, fetch, record) do
      case hold(fetch, kind, record) do
        {:ok, fetch} -> settle(state, request_id, fetch)
        :full -> {state, :ignored}
      end
    else
      {state, :ignored}
    end
  end

  defp accepted?(current, fetch, record) do
    if DateTime.compare(record.fetched_at, fetch.fetched_at) == :eq do
      not superseded?(current, record)
    else
      false
    end
  end

  defp superseded?(nil, _record), do: false
  defp superseded?(%{request_id: request_id}, %{request_id: request_id}), do: true

  defp superseded?(%{fetched_at: current_fetched_at}, %{fetched_at: fetched_at}) do
    DateTime.before?(fetched_at, current_fetched_at)
  end

  defp hold(fetch, :manifest, %{agency_ids: agency_ids}) do
    {:ok, %{fetch | agency_ids: agency_ids}}
  end

  defp hold(%{agencies: agencies} = fetch, :agency, %{agency: %{"id" => id} = agency}) do
    if is_map_key(agencies, id) or map_size(agencies) < @agency_count_max do
      {:ok, %{fetch | agencies: Map.put(agencies, id, agency)}}
    else
      :full
    end
  end

  defp settle(state, request_id, fetch) do
    if complete?(fetch) do
      {switch(state, request_id, fetch), :switched}
    else
      held = state.held |> Map.put(request_id, fetch) |> bound()
      {%{state | held: held}, :held}
    end
  end

  defp complete?(%{agency_ids: nil}), do: false

  defp complete?(%{agency_ids: agency_ids, agencies: agencies}) do
    Enum.all?(agency_ids, &is_map_key(agencies, &1))
  end

  defp switch(%{held: held}, request_id, fetch) do
    current = %{
      request_id: request_id,
      fetched_at: fetch.fetched_at,
      agency_ids: fetch.agency_ids,
      agencies: Map.take(fetch.agencies, fetch.agency_ids)
    }

    held =
      held
      |> Map.delete(request_id)
      |> Map.reject(fn {_request_id, other} ->
        DateTime.before?(other.fetched_at, fetch.fetched_at)
      end)

    %{current: current, held: held}
  end

  defp bound(held) do
    if map_size(held) <= @held_fetch_count_max do
      held
    else
      {oldest, _fetch} =
        Enum.min_by(
          held,
          fn {request_id, fetch} ->
            {DateTime.to_unix(fetch.fetched_at, :microsecond), request_id}
          end
        )

      Map.delete(held, oldest)
    end
  end
end
