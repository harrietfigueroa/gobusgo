defmodule Gobusgo.OneBusAway.VehicleView.State do
  @agency_count_max 64
  @held_fetch_count_max 32
  @vehicle_count_max 5_000

  @moduledoc """
  The rules of the vehicle view: which fetch is current for each agency, and
  which records are held until their fetch is complete. Everything here is
  pure.

  A fetch holds the vehicles of one agency. It is complete when its manifest
  and every vehicle the manifest names have been put. The view switches an
  agency to a complete fetch in one step, so an agency's current fetch always
  holds exactly the vehicles its manifest names, and a fetch of one agency
  leaves the current fetch of every other agency as it is.

  A record is ignored when its fetch is its agency's current one or is older
  than it, so records published again change nothing and an old fetch never
  replaces a newer one. A fetch with the same fetch time as the agency's
  current one and another request identifier replaces it. A record is also
  ignored when its fetch time or its agency differs from the ones its fetch
  is held under.

  At most #{@agency_count_max} agencies have a current fetch; the fetch of
  an agency beyond that is ignored. At most #{@held_fetch_count_max}
  incomplete fetches are held, the oldest forgotten first, each with at most
  #{@vehicle_count_max} vehicles. A switch forgets every held fetch of the
  same agency older than the new current one.
  """

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.RequestId

  @type vehicle :: %{String.t() => term()}

  @type fetch :: %{
          agency_id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          vehicle_ids: [String.t()],
          vehicles: %{String.t() => vehicle()}
        }

  @type held :: %{
          agency_id: String.t(),
          fetched_at: DateTime.t(),
          vehicles: %{String.t() => vehicle()},
          vehicle_ids: [String.t()] | nil
        }

  @type t :: %{current: %{String.t() => fetch()}, held: %{RequestId.t() => held()}}

  @type outcome :: :held | :switched | :ignored

  @doc "A view with no current fetch and nothing held."
  @spec new() :: t()
  def new, do: %{current: %{}, held: %{}}

  @doc "Agencies that have a current fetch at once."
  @spec agency_count_max() :: pos_integer()
  def agency_count_max, do: @agency_count_max

  @doc "Incomplete fetches held at once."
  @spec held_fetch_count_max() :: pos_integer()
  def held_fetch_count_max, do: @held_fetch_count_max

  @doc "The current fetch of every agency that has one, by agency identifier."
  @spec current(t()) :: %{String.t() => fetch()}
  def current(%{current: current}), do: current

  @doc "Applies one decoded record and says what became of it."
  @spec put(t(), Records.decoded()) :: {t(), outcome()}
  def put(%{current: current, held: held} = state, {kind, %{request_id: request_id} = record}) do
    %{agency_id: agency_id, fetched_at: fetched_at} = record

    fetch =
      Map.get(held, request_id, %{
        agency_id: agency_id,
        fetched_at: fetched_at,
        vehicles: %{},
        vehicle_ids: nil
      })

    if accepted?(current, fetch, record) do
      case hold(fetch, kind, record) do
        {:ok, fetch} -> settle(state, request_id, fetch)
        :full -> {state, :ignored}
      end
    else
      {state, :ignored}
    end
  end

  defp accepted?(current, fetch, %{agency_id: agency_id} = record) do
    if same_fetch?(fetch, record) do
      case Map.fetch(current, agency_id) do
        {:ok, agency_current} -> not superseded?(agency_current, record)
        :error -> map_size(current) < @agency_count_max
      end
    else
      false
    end
  end

  defp same_fetch?(%{agency_id: agency_id, fetched_at: held_fetched_at}, record) do
    if record.agency_id == agency_id do
      DateTime.compare(record.fetched_at, held_fetched_at) == :eq
    else
      false
    end
  end

  defp superseded?(%{request_id: request_id}, %{request_id: request_id}), do: true

  defp superseded?(%{fetched_at: current_fetched_at}, %{fetched_at: fetched_at}) do
    DateTime.before?(fetched_at, current_fetched_at)
  end

  defp hold(fetch, :manifest, %{vehicle_ids: vehicle_ids}) do
    {:ok, %{fetch | vehicle_ids: vehicle_ids}}
  end

  defp hold(%{vehicles: vehicles} = fetch, :vehicle, %{vehicle: %{"id" => id} = vehicle}) do
    if is_map_key(vehicles, id) or map_size(vehicles) < @vehicle_count_max do
      {:ok, %{fetch | vehicles: Map.put(vehicles, id, vehicle)}}
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

  defp complete?(%{vehicle_ids: nil}), do: false

  defp complete?(%{vehicle_ids: vehicle_ids, vehicles: vehicles}) do
    Enum.all?(vehicle_ids, &is_map_key(vehicles, &1))
  end

  defp switch(%{current: current, held: held}, request_id, %{agency_id: agency_id} = fetch) do
    agency_current = %{
      agency_id: agency_id,
      request_id: request_id,
      fetched_at: fetch.fetched_at,
      vehicle_ids: fetch.vehicle_ids,
      vehicles: Map.take(fetch.vehicles, fetch.vehicle_ids)
    }

    held =
      held
      |> Map.delete(request_id)
      |> Map.reject(fn {_request_id, other} -> older_of_agency?(other, fetch) end)

    %{current: Map.put(current, agency_id, agency_current), held: held}
  end

  defp older_of_agency?(%{agency_id: agency_id} = other, %{agency_id: agency_id} = fetch) do
    DateTime.before?(other.fetched_at, fetch.fetched_at)
  end

  defp older_of_agency?(_other, _fetch), do: false

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
