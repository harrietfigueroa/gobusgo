defmodule Gobusgo.OneBusAway.VehicleFilter do
  @agency_field "agency"
  @route_field "route"

  @moduledoc """
  The vehicle adapter of the filter contract in `Gobusgo.Filter`: the fields
  a vehicle can be filtered by, and the vehicles of a fetch that a filter
  keeps. Everything here is pure.

  The fields are `#{@agency_field}`, the identifier of the agency whose
  fetch holds the vehicle, and `#{@route_field}`, the identifier of the
  route of the vehicle's trip. Every vehicle of a fetch has the agency. A
  vehicle with no route matches no filter that names a route.
  """

  @behaviour Gobusgo.Filter

  alias Gobusgo.Assert
  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.VehicleView.State

  @spec_fields %{@agency_field => :string, @route_field => :string}

  @typedoc "One vehicle of a fetch, with the agency the fetch is of."
  @type vehicle_record :: %{agency_id: String.t(), vehicle: State.vehicle()}

  @impl Gobusgo.Filter
  def spec, do: @spec_fields

  @impl Gobusgo.Filter
  @spec values(vehicle_record()) :: Filter.values()
  def values(%{agency_id: agency_id, vehicle: vehicle})
      when is_binary(agency_id) and is_map(vehicle) do
    route_id = Map.get(vehicle, "routeId")

    Assert.condition(
      is_nil(route_id) or is_binary(route_id),
      "vehicle route must be a string or nil, got: #{inspect(route_id)}"
    )

    %{@agency_field => agency_id, @route_field => route_id}
  end

  @doc """
  Returns the vehicle filter that `raw` stands for, or every violation, as
  `Gobusgo.Filter.normalize/1` does under `spec/0`.
  """
  @spec normalize(Filter.raw()) :: {:ok, Filter.t()} | {:error, [Filter.violation(), ...]}
  def normalize(raw) when is_map(raw), do: Filter.normalize(%{raw: raw, spec: @spec_fields})

  @doc """
  Whether `filter` can keep a vehicle of a fetch of the agency `agency_id`,
  judged by the agency alone. A fetch of an agency it does not keep has no
  vehicle to read; which vehicles of a kept agency's fetch it keeps is
  `filter_fetch/1`'s to say.
  """
  @spec keeps_agency?(%{filter: Filter.t(), agency_id: String.t()}) :: boolean()
  def keeps_agency?(%{filter: filter, agency_id: agency_id})
      when is_map(filter) and is_binary(agency_id) do
    Filter.matches?(%{
      filter: Map.take(filter, [@agency_field]),
      values: %{@agency_field => agency_id}
    })
  end

  @doc """
  Returns `fetch`, one agency's fetch, with only the vehicles that match
  `filter`, in the fetch's vehicle order. A fetch none of whose vehicles
  match is returned with no vehicle. Raises
  `Gobusgo.Assert.AssertionError` for a filter that names a field outside
  `spec/0`.
  """
  @spec filter_fetch(%{filter: Filter.t(), fetch: State.fetch()}) :: State.fetch()
  def filter_fetch(%{filter: filter, fetch: %{agency_id: agency_id} = fetch})
      when is_map(filter) do
    Enum.each(filter, fn {field, _accepted} ->
      Assert.condition(
        is_map_key(@spec_fields, field),
        "vehicle filter must name fields of the specification, got: #{inspect(field)}"
      )
    end)

    %{vehicle_ids: vehicle_ids, vehicles: vehicles} = fetch

    kept_ids =
      Enum.filter(vehicle_ids, fn vehicle_id ->
        record = %{agency_id: agency_id, vehicle: Map.fetch!(vehicles, vehicle_id)}
        Filter.matches?(%{filter: filter, values: values(record)})
      end)

    kept = %{fetch | vehicle_ids: kept_ids, vehicles: Map.take(vehicles, kept_ids)}
    Assert.condition(map_size(kept.vehicles) == length(kept_ids), "kept vehicles must be unique")
    kept
  end
end
