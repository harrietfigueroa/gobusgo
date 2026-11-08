defmodule Gobusgo.Gbfs.VehicleTypeRecords do
  alias Gobusgo.CloudEvent

  @topic "gbfs.vehicle-types.state"
  @source "/gobusgo/cycle/gbfs/vehicle-types"
  @key_prefix "vehicle-types/"
  @type_name CloudEvent.type(%{name: "gbfs.vehicle_types.fetched", version: 1})

  @moduledoc """
  The published form of one fetch of a system's `vehicle_types` at one GBFS
  version: one record that holds every type of the file. Everything here is
  pure, so a repeated build yields the same bytes.

  A type identifier names a type within its version alone, so a system's
  types are one record per version and a view holds them under
  `id/1`, `<system id>/<version>`.

  The record goes to the topic `#{@topic}` and holds one `Gobusgo.CloudEvent`
  whose `source` is `#{@source}` and whose `time` is the fetch time.

    * Key: `#{@key_prefix}<system id>/<version>`, so the newest fetch of a
      version replaces its earlier ones.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>/#{@key_prefix}<system id>/<version>`.
    * `subject`: `<system id>/<version>`.
    * `data.systemId` and `data.version`: the system and the version.
    * `data.vehicleTypes`: the types in identifier order, each with `id`,
      `formFactor` and `propulsionType`, the file's strings, and
      `maxRangeMeters`, `null` where the file leaves it out.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @type vehicle_type :: %{
          form_factor: String.t(),
          propulsion_type: String.t(),
          max_range_meters: number() | nil
        }

  @typedoc "What one record holds, with the types by identifier."
  @type decoded :: %{
          id: String.t(),
          system_id: String.t(),
          version: Files.version(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          vehicle_types: %{String.t() => vehicle_type()}
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @data_schema {:map,
                %{
                  "systemId" => :string,
                  "version" => :string,
                  "vehicleTypes" =>
                    {:list,
                     {:map,
                      %{
                        "id" => :string,
                        "formFactor" => :string,
                        "propulsionType" => :string,
                        "maxRangeMeters" => {:nullable, :number}
                      }}},
                  "fetchedAt" => :string,
                  "requestId" => :string
                }}

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The identifier a view holds the types of `system_id` at `version` under."
  @spec id(%{system_id: String.t(), version: Files.version()}) :: String.t()
  def id(%{system_id: system_id, version: version})
      when is_binary(system_id) and is_binary(version) do
    system_id <> "/" <> version
  end

  @doc """
  Returns the record that publishes one fetch: `vehicle_types` as
  `Gobusgo.Gbfs.Files.vehicle_types/1` parses them, of `system_id` at
  `version`. Raises `Gobusgo.Assert.AssertionError` when the request
  identifier is not a UUID version 7, the system identifier is empty, the
  version publishes no `vehicle_types`, or a type identifier repeats.
  """
  @spec build(%{
          system_id: String.t(),
          version: Files.version(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          vehicle_types: [Files.vehicle_type()]
        }) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = fetch) do
    %{system_id: system_id, version: version, vehicle_types: vehicle_types} = fetch
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(system_id), "system identifier must be a string")
    Assert.condition(system_id != "", "system identifier must be non-empty")

    Assert.condition(
      version in Files.vehicle_types_versions(),
      "vehicle_types exists in #{inspect(Files.vehicle_types_versions())}, got: #{inspect(version)}"
    )

    vehicle_types = Enum.sort_by(vehicle_types, & &1.id)
    type_ids = Enum.map(vehicle_types, & &1.id)
    Assert.condition(type_ids == Enum.dedup(type_ids), "type identifiers must be unique")
    subject = id(%{system_id: system_id, version: version})
    key = @key_prefix <> subject

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: subject,
      partition_key: key,
      data: %{
        "systemId" => system_id,
        "version" => version,
        "vehicleTypes" => Enum.map(vehicle_types, &type_data/1),
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "requestId" => request_id
      }
    })
  end

  defp type_data(vehicle_type) do
    %{
      "id" => vehicle_type.id,
      "formFactor" => vehicle_type.form_factor,
      "propulsionType" => vehicle_type.propulsion_type,
      "maxRangeMeters" => vehicle_type.max_range_meters
    }
  end

  @doc """
  Returns what `value`, the value of a record `build/1` produces, holds. The
  first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @type_name -> decode_data(data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_data(data) do
    with nil <- Schema.mismatch(data, @data_schema),
         %{"systemId" => system_id, "version" => version, "requestId" => request_id} = data,
         true <- system_id != "",
         true <- version in Files.vehicle_types_versions(),
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]),
         type_ids = Enum.map(data["vehicleTypes"], & &1["id"]),
         true <- type_ids == Enum.uniq(type_ids) do
      {:ok,
       %{
         id: id(%{system_id: system_id, version: version}),
         system_id: system_id,
         version: version,
         request_id: request_id,
         fetched_at: fetched_at,
         vehicle_types: Map.new(data["vehicleTypes"], &decode_type/1)
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp decode_type(entry) do
    {entry["id"],
     %{
       form_factor: entry["formFactor"],
       propulsion_type: entry["propulsionType"],
       max_range_meters: entry["maxRangeMeters"]
     }}
  end
end
