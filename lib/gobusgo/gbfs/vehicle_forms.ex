defmodule Gobusgo.Gbfs.VehicleForms do
  @form_factors [:standing_scooter, :seated_scooter, :e_bike, :bike, :other]

  @moduledoc """
  The form factor and the maximum range of one shared vehicle, read from the
  vehicle types of the system and the GBFS version its vehicle file came
  from. Everything here is pure: the types arrive as the fetches of the
  vehicle type view.

  The form factors are #{inspect(@form_factors)}. A type identifier names a
  type within its version alone, so a vehicle is looked up in the fetch of
  its own system and version and never another. A vehicle whose type that
  fetch does not hold, a vehicle with no type, and any vehicle of a version
  that publishes no `vehicle_types`, such as 1.0, is `:other` with no range.

  A type's form factor and propulsion decide its form:

    * `scooter_standing` (3.0) and `scooter` (2.2): `:standing_scooter`.
      2.2 names no seated scooter, so its `scooter` reads as standing.
    * `scooter_seated` (3.0): `:seated_scooter`.
    * `bicycle` and `cargo_bicycle`: `:e_bike` with `electric_assist` or
      `electric` propulsion, `:bike` with `human`.
    * Anything else: `:other`, with the type's range.
  """

  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.VehicleTypeRecords

  @type form_factor :: :standing_scooter | :seated_scooter | :e_bike | :bike | :other
  @type form :: %{form_factor: form_factor(), max_range_meters: number() | nil}

  # The form factors and propulsion types of GBFS 2.2 and 3.0.
  # https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#vehicle_typesjson — checked 2026-11-08
  # https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md#vehicle_typesjson-added-in-v21 — checked 2026-11-08
  @bicycle_form_factors ["bicycle", "cargo_bicycle"]
  @motor_propulsion_types ["electric_assist", "electric"]
  @human_propulsion_type "human"

  @doc "The form factors a lookup gives."
  @spec form_factors() :: [form_factor()]
  def form_factors, do: @form_factors

  @doc """
  Returns the form of the vehicle of type `vehicle_type_id`, `nil` for a
  vehicle with none, in the vehicle file of `system_id` at `version`.
  `fetches` are the current fetches of the vehicle type view, as
  `Gobusgo.Gbfs.VehicleTypeRecords.decode/1` returns them.
  """
  @spec lookup([VehicleTypeRecords.decoded()], %{
          system_id: String.t(),
          version: Files.version(),
          vehicle_type_id: String.t() | nil
        }) :: form()
  def lookup(fetches, %{system_id: system_id, version: version, vehicle_type_id: type_id})
      when is_list(fetches) and is_binary(system_id) and is_binary(version) do
    fetch = Enum.find(fetches, &fetch_of?(&1, %{system_id: system_id, version: version}))

    vehicle_type =
      case {fetch, type_id} do
        {nil, _type_id} -> nil
        {_fetch, nil} -> nil
        {%{vehicle_types: vehicle_types}, type_id} -> Map.get(vehicle_types, type_id)
      end

    case vehicle_type do
      nil ->
        %{form_factor: :other, max_range_meters: nil}

      %{max_range_meters: max_range_meters} = vehicle_type ->
        %{form_factor: form_factor(vehicle_type), max_range_meters: max_range_meters}
    end
  end

  defp fetch_of?(%{system_id: system_id, version: version}, %{
         system_id: system_id,
         version: version
       }), do: true

  defp fetch_of?(_fetch, _key), do: false

  defp form_factor(%{form_factor: "scooter_standing"}), do: :standing_scooter
  defp form_factor(%{form_factor: "scooter"}), do: :standing_scooter
  defp form_factor(%{form_factor: "scooter_seated"}), do: :seated_scooter

  defp form_factor(%{form_factor: form_factor, propulsion_type: propulsion_type})
       when form_factor in @bicycle_form_factors and propulsion_type in @motor_propulsion_types,
       do: :e_bike

  defp form_factor(%{form_factor: form_factor, propulsion_type: @human_propulsion_type})
       when form_factor in @bicycle_form_factors, do: :bike

  defp form_factor(_vehicle_type), do: :other
end
