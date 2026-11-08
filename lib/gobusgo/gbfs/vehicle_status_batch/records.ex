defmodule Gobusgo.Gbfs.VehicleStatusBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "gbfs.free-bike-status.state"
  @fetched_source "/gobusgo/processor/gbfs/free-bike-status"
  @not_published_source "/gobusgo/recorder/gbfs/free-bike-status"
  @key_prefix "vehicle-status/"
  @fetched_type CloudEvent.type(%{name: "shared-vehicles.processed", version: 1})
  @not_published_type CloudEvent.type(%{name: "shared-vehicles.not-published", version: 1})

  @moduledoc """
  The published forms of a system's shared vehicles, one record per fetch.
  Everything here is pure, so a record is a function of its fetch alone and
  a repeated build yields the same bytes.

  A record goes to the topic `#{@topic}` under the key
  `#{@key_prefix}<system id>`, so a system's newest record replaces its
  earlier ones, and holds one `Gobusgo.CloudEvent` whose `subject` is the
  system identifier and whose `id` is `<requestId>/#{@key_prefix}<system id>`.
  Nothing in a record is keyed on a vehicle identifier: GBFS rotates it, so a
  record holds the whole fetch and replaces the one before it whole.

  ## A fetch

  `type` `#{@fetched_type}`, `source` `#{@fetched_source}`, and the fetch
  time as `time`:

    * `data.systemId`, `data.version`: the system and the GBFS version that
      answered, which decides what a vehicle's type identifier means.
    * `data.lastUpdated`, `data.ttl`: the file's own, in UTC extended ISO
      8601 and seconds.
    * `data.vehicles`: the vehicles in the file's order, each with `id`,
      `lat`, `lon`, `vehicleTypeId`, `currentRangeMeters`, `isDisabled`,
      `isReserved`, and `lastReported`, a field the file leaves out as
      `null`; `lat` and `lon` are `null` together.
    * `data.dataSha256`, `data.destination`, `data.fetchedAt`,
      `data.requestId`: the hash, the destination, the fetch time, and the
      request of the stored file.

  ## A feed that is not published

  `type` `#{@not_published_type}`, `source` `#{@not_published_source}`, and
  the time of the fetch that found every version passed over as `time`,
  with `data.systemId`, `data.checkedAt`, and `data.requestId`. It holds no
  vehicle.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc "One fetch, as `build_fetched/1` takes it and `decode/1` returns it."
  @type fetched :: %{
          kind: :fetched,
          id: String.t(),
          version: Files.version(),
          last_updated: DateTime.t(),
          ttl: non_neg_integer(),
          vehicles: [Files.vehicle()],
          data_sha256: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          request_id: RequestId.t()
        }

  @typedoc "A feed found not published, as `build_not_published/1` takes it and `decode/1` returns it."
  @type not_published :: %{
          kind: :not_published,
          id: String.t(),
          fetched_at: DateTime.t(),
          request_id: RequestId.t()
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record this module builds.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @vehicle_schema {:map,
                   %{
                     "id" => :string,
                     "lat" => {:nullable, :number},
                     "lon" => {:nullable, :number},
                     "vehicleTypeId" => {:nullable, :string},
                     "currentRangeMeters" => {:nullable, :number},
                     "isDisabled" => :boolean,
                     "isReserved" => :boolean,
                     "lastReported" => {:nullable, :string}
                   }}

  @fetched_schema {:map,
                   %{
                     "systemId" => :string,
                     "version" => :string,
                     "lastUpdated" => :string,
                     "ttl" => :integer,
                     "vehicles" => {:list, @vehicle_schema},
                     "dataSha256" => :string,
                     "destination" => :string,
                     "fetchedAt" => :string,
                     "requestId" => :string
                   }}

  @not_published_schema {:map,
                         %{
                           "systemId" => :string,
                           "checkedAt" => :string,
                           "requestId" => :string
                         }}

  @doc "The topic the records go to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the record that publishes `fetched`. Raises
  `Gobusgo.Assert.AssertionError` when an identifier breaks its contract.
  """
  @spec build_fetched(fetched()) :: Publisher.topic_record()
  def build_fetched(%{kind: :fetched, id: system_id, request_id: request_id} = fetched) do
    %{fetched_at: %DateTime{} = fetched_at, last_updated: %DateTime{} = last_updated} = fetched
    assert_identifiers(system_id, request_id)
    Assert.condition(fetched.version in Files.versions(), "version must be known")

    data = %{
      "systemId" => system_id,
      "version" => fetched.version,
      "lastUpdated" => DateTime.to_iso8601(last_updated, :extended),
      "ttl" => fetched.ttl,
      "vehicles" => Enum.map(fetched.vehicles, &vehicle_data/1),
      "dataSha256" => fetched.data_sha256,
      "destination" => fetched.destination,
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "requestId" => request_id
    }

    record(%{
      system_id: system_id,
      request_id: request_id,
      source: @fetched_source,
      type: @fetched_type,
      time: fetched_at,
      data: data
    })
  end

  @doc """
  Returns the record that publishes `not_published`. Raises
  `Gobusgo.Assert.AssertionError` when an identifier breaks its contract.
  """
  @spec build_not_published(not_published()) :: Publisher.topic_record()
  def build_not_published(%{kind: :not_published, id: system_id, request_id: request_id} = found) do
    %{fetched_at: %DateTime{} = checked_at} = found
    assert_identifiers(system_id, request_id)

    record(%{
      system_id: system_id,
      request_id: request_id,
      source: @not_published_source,
      type: @not_published_type,
      time: checked_at,
      data: %{
        "systemId" => system_id,
        "checkedAt" => DateTime.to_iso8601(checked_at, :extended),
        "requestId" => request_id
      }
    })
  end

  @doc """
  Returns what `value`, the value of a record this module builds, holds. The
  first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, fetched() | not_published()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @fetched_type -> decode_fetched(data)
        @not_published_type -> decode_not_published(data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp record(%{system_id: system_id, request_id: request_id} = event) do
    key = @key_prefix <> system_id

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: event.source,
      type: event.type,
      time: event.time,
      subject: system_id,
      partition_key: key,
      data: event.data
    })
  end

  defp vehicle_data(vehicle) do
    {lat, lon} =
      case vehicle.position do
        %{lat: lat, lon: lon} -> {lat, lon}
        nil -> {nil, nil}
      end

    last_reported =
      case vehicle.last_reported do
        %DateTime{} = last_reported -> DateTime.to_iso8601(last_reported, :extended)
        nil -> nil
      end

    %{
      "id" => vehicle.id,
      "lat" => lat,
      "lon" => lon,
      "vehicleTypeId" => vehicle.vehicle_type_id,
      "currentRangeMeters" => vehicle.current_range_meters,
      "isDisabled" => vehicle.is_disabled,
      "isReserved" => vehicle.is_reserved,
      "lastReported" => last_reported
    }
  end

  defp decode_fetched(data) do
    with nil <- Schema.mismatch(data, @fetched_schema),
         %{"systemId" => system_id, "requestId" => request_id} = data,
         true <- Systems.id?(system_id),
         true <- RequestId.valid?(request_id),
         true <- data["version"] in Files.versions(),
         {:ok, fetched_at} <- timestamp(data["fetchedAt"]),
         {:ok, last_updated} <- timestamp(data["lastUpdated"]),
         {:ok, vehicles} <- vehicles(data["vehicles"]) do
      {:ok,
       %{
         kind: :fetched,
         id: system_id,
         version: data["version"],
         last_updated: last_updated,
         ttl: data["ttl"],
         vehicles: vehicles,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         fetched_at: fetched_at,
         request_id: request_id
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp decode_not_published(data) do
    with nil <- Schema.mismatch(data, @not_published_schema),
         %{"systemId" => system_id, "requestId" => request_id} = data,
         true <- Systems.id?(system_id),
         true <- RequestId.valid?(request_id),
         {:ok, checked_at} <- timestamp(data["checkedAt"]) do
      {:ok,
       %{kind: :not_published, id: system_id, fetched_at: checked_at, request_id: request_id}}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  # The vehicles are read in one pass, which stops at the first that breaks
  # a rule.
  defp vehicles(vehicles_data) do
    vehicles =
      Enum.reduce_while(vehicles_data, [], fn data, vehicles ->
        case vehicle(data) do
          {:ok, vehicle} -> {:cont, [vehicle | vehicles]}
          :error -> {:halt, :error}
        end
      end)

    case vehicles do
      :error -> :error
      vehicles -> {:ok, Enum.reverse(vehicles)}
    end
  end

  defp vehicle(%{"lat" => lat, "lon" => lon, "lastReported" => last_reported_text} = data) do
    position =
      case {lat, lon} do
        {nil, nil} -> {:ok, nil}
        {lat, lon} when is_number(lat) and is_number(lon) -> {:ok, %{lat: lat, lon: lon}}
        _one_missing -> :error
      end

    last_reported =
      case last_reported_text do
        nil -> {:ok, nil}
        text -> timestamp(text)
      end

    case {position, last_reported} do
      {{:ok, position}, {:ok, last_reported}} ->
        {:ok,
         %{
           id: data["id"],
           position: position,
           vehicle_type_id: data["vehicleTypeId"],
           current_range_meters: data["currentRangeMeters"],
           is_disabled: data["isDisabled"],
           is_reserved: data["isReserved"],
           last_reported: last_reported
         }}

      _broken ->
        :error
    end
  end

  defp timestamp(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, 0} -> {:ok, time}
      _other -> :error
    end
  end

  defp assert_identifiers(system_id, request_id) do
    Systems.assert_id(system_id)
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
  end
end
