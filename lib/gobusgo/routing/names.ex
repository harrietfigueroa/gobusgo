defmodule Gobusgo.Routing.Names do
  @version 1

  @moduledoc """
  The names file of a routing snapshot, version #{@version}: the display
  names a page shows beside a journey or a scheduled arrival with no view to
  read them from (decided in GOB-251). Everything here is pure.

  The file is one JSON object, encoded with sorted keys and stored as one
  gzip stream. Stops and trips are keyed by their index in the snapshot's
  stops and trips files, the keys the connections already carry, so a
  column is a list in the order of its file and holds no identifier.
  Routes and agencies have no index in a snapshot and are keyed by
  identifier.

    * `version`: #{@version}.
    * `stopNames` and `stopCodes`: per stop of the stops file, its name and
      its code, or `null` where the stop view holds none.
    * `tripHeadsigns`: per trip of the trips file, its headsign, or `null`
      where its schedule has none.
    * `routes`: per route a trip names that the route view holds, its
      `shortName`, `longName`, `color`, six hexadecimal digits, and
      `agencyId`, each `null` where the source supplies none.
    * `agencyNames`: per agency those routes name that the agency view
      holds, its name.

  `decode/1` refuses a file of another version, and one whose fields are not
  of these shapes.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.Routing.SnapshotFormat
  alias Gobusgo.Schema

  @typedoc "A stop's names, each `nil` where the stop view holds none."
  @type stop_names :: %{name: String.t() | nil, code: String.t() | nil}

  @typedoc "A route's names as the route view holds them, each `nil` where the source supplies none."
  @type route_names :: %{
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          color: String.t() | nil,
          agency_id: String.t() | nil
        }

  @typedoc "The headsign of each trip by service day offset and identifier."
  @type headsigns :: %{{0 | 1, String.t()} => String.t() | nil}

  @typedoc """
    * `:invalid_json` — the file is not JSON.
    * `:unsupported_version` — the file names another version.
    * `:schema_mismatch` — a field is not of its shape.
  """
  @type decode_error :: :invalid_json | :unsupported_version | :schema_mismatch

  @schema {:map,
           %{
             "version" => :integer,
             "stopNames" => {:list, {:nullable, :string}},
             "stopCodes" => {:list, {:nullable, :string}},
             "tripHeadsigns" => {:list, {:nullable, :string}}
           }}

  @route_schema {:map,
                 %{
                   "shortName" => {:nullable, :string},
                   "longName" => {:nullable, :string},
                   "color" => {:nullable, :string},
                   "agencyId" => {:nullable, :string}
                 }}

  @doc "The version of the names file this module writes and reads."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Returns the headsign of every trip of `schedules`, those of the snapshot's
  service date, and `previous_schedules`, those of the date before, keyed as
  `Gobusgo.Routing.Timetable` keys its trips.
  """
  @spec headsigns(%{
          schedules: [CompactSchedule.t()],
          previous_schedules: [CompactSchedule.t()]
        }) :: headsigns()
  def headsigns(%{schedules: schedules, previous_schedules: previous_schedules})
      when is_list(schedules) and is_list(previous_schedules) do
    for {offset, offset_schedules} <- [{0, schedules}, {1, previous_schedules}],
        schedule <- offset_schedules,
        trip <- schedule.trips,
        into: %{},
        do: {{offset, trip.id}, trip.headsign}
  end

  @doc """
  Returns the names of the snapshot whose stops file holds `stop_ids` and
  whose trips file holds `trips`, from `stops` and `routes`, the names the
  stop view and the route view hold by identifier, `agency_names`, the name
  of each agency of the agency view, and `headsigns`.
  """
  @spec build(%{
          stop_ids: [String.t()],
          trips: [SnapshotFormat.trip()],
          headsigns: headsigns(),
          stops: %{String.t() => stop_names()},
          routes: %{String.t() => route_names()},
          agency_names: %{String.t() => String.t()}
        }) :: map()
  def build(%{stop_ids: stop_ids, trips: trips, headsigns: headsigns} = input)
      when is_list(stop_ids) and is_list(trips) and is_map(headsigns) do
    stop_names = for stop_id <- stop_ids, do: Map.get(input.stops, stop_id)

    route_ids = trips |> Enum.map(& &1.route_id) |> Enum.uniq()

    routes =
      for route_id <- route_ids,
          route = Map.get(input.routes, route_id),
          route != nil,
          into: %{},
          do: {route_id, route}

    agency_names =
      for {_route_id, %{agency_id: agency_id}} <- routes,
          is_map_key(input.agency_names, agency_id),
          into: %{},
          do: {agency_id, Map.fetch!(input.agency_names, agency_id)}

    names = %{
      "version" => @version,
      "stopNames" => Enum.map(stop_names, &(&1 && &1.name)),
      "stopCodes" => Enum.map(stop_names, &(&1 && &1.code)),
      "tripHeadsigns" =>
        for(trip <- trips, do: Map.get(headsigns, {trip.service_day_offset, trip.id})),
      "routes" => Map.new(routes, fn {route_id, route} -> {route_id, route_entry(route)} end),
      "agencyNames" => agency_names
    }

    Assert.condition(
      length(names["stopNames"]) == length(stop_ids),
      "one stop name per stop, got: #{length(names["stopNames"])} for #{length(stop_ids)}"
    )

    Assert.condition(
      length(names["tripHeadsigns"]) == length(trips),
      "one headsign per trip, got: #{length(names["tripHeadsigns"])} for #{length(trips)}"
    )

    names
  end

  defp route_entry(route) do
    %{
      "shortName" => route.short_name,
      "longName" => route.long_name,
      "color" => route.color,
      "agencyId" => route.agency_id
    }
  end

  @doc "Returns the content of the names file that holds `names`, before compression."
  @spec encode(map()) :: binary()
  def encode(%{"version" => @version} = names), do: CanonicalJson.encode(names)

  @doc "Returns the names a names file's content holds, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, map()} | {:error, decode_error()}
  def decode(content) when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"version" => @version} = names} -> checked(names)
      {:ok, %{"version" => version}} when is_integer(version) -> {:error, :unsupported_version}
      {:ok, _other} -> {:error, :schema_mismatch}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp checked(names) do
    routes = Map.get(names, "routes")
    agency_names = Map.get(names, "agencyNames")

    cond do
      Schema.mismatch(names, @schema) != nil ->
        {:error, :schema_mismatch}

      length(names["stopNames"]) != length(names["stopCodes"]) ->
        {:error, :schema_mismatch}

      not keyed?(routes, &(Schema.mismatch(&1, @route_schema) == nil)) ->
        {:error, :schema_mismatch}

      not keyed?(agency_names, &is_binary/1) ->
        {:error, :schema_mismatch}

      true ->
        {:ok, names}
    end
  end

  # Whether `value` is a map whose every value passes `valid?`.
  defp keyed?(value, valid?) when is_map(value),
    do: Enum.all?(value, fn {_key, entry} -> valid?.(entry) end)

  defp keyed?(_value, _valid?), do: false
end
