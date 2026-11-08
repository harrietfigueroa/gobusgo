defmodule Gobusgo.Gbfs.Files do
  @versions ["3.0", "2.2", "1.0"]
  @vehicle_types_versions ["3.0", "2.2"]

  @moduledoc """
  The GBFS files the client reads, as schemas and as the records parsed out
  of them: the discovery file `gbfs.json`, the vehicle file, and
  `vehicle_types`. Everything here is pure.

  The versions are #{Enum.join(@versions, ", ")}, newest first. The vehicle
  file is `free_bike_status` up to 2.2 and `vehicle_status` in 3.0;
  `vehicle_types` exists in #{Enum.join(@vehicle_types_versions, " and ")}
  alone. A version names its file format: 1.0 and 2.2 write a timestamp as
  POSIX seconds and 3.0 as an RFC 3339 string, and 1.0 writes a flag as 1
  or 0 where the later versions write a boolean.

  A parser returns the record or the first cause that the document breaks
  the format of its version:

    * `{:schema_mismatch, mismatch}`: a field is absent or of another type,
      as `Gobusgo.Schema` reports it
    * `{:invalid_timestamp, path}`: a timestamp field names no time
    * `{:out_of_range, path}`: a number lies outside what its field allows

  A path is that of `Gobusgo.Schema`, from the document's root.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Schema

  @latitude_max 90
  @longitude_max 180

  @type version :: String.t()
  @type path :: Schema.path()
  @type cause ::
          {:schema_mismatch, Schema.mismatch()}
          | {:invalid_timestamp, path()}
          | {:out_of_range, path()}

  @type discovery :: %{
          last_updated: DateTime.t(),
          ttl: non_neg_integer(),
          feeds: %{String.t() => String.t()}
        }
  @type vehicle :: %{
          id: String.t(),
          position: %{lat: number(), lon: number()} | nil,
          vehicle_type_id: String.t() | nil,
          current_range_meters: number() | nil,
          is_disabled: boolean(),
          is_reserved: boolean(),
          last_reported: DateTime.t() | nil
        }
  @type vehicle_status :: %{
          last_updated: DateTime.t(),
          ttl: non_neg_integer(),
          vehicles: [vehicle()]
        }
  @type vehicle_types :: %{
          last_updated: DateTime.t(),
          ttl: non_neg_integer(),
          vehicle_types: [vehicle_type()]
        }
  @type vehicle_type :: %{
          id: String.t(),
          form_factor: String.t(),
          propulsion_type: String.t(),
          max_range_meters: number() | nil
        }

  @feed_schema {:map, %{"name" => :string, "url" => :string}}

  @doc "The versions a parser reads, newest first."
  @spec versions() :: [version()]
  def versions, do: @versions

  @doc "The versions that publish `vehicle_types`, newest first."
  @spec vehicle_types_versions() :: [version()]
  def vehicle_types_versions, do: @vehicle_types_versions

  @doc "The name the discovery file of `version` gives the vehicle file."
  @spec vehicle_status_name(version()) :: String.t()
  def vehicle_status_name(version) do
    case format(version) do
      :v1 -> "free_bike_status"
      :v2 -> "free_bike_status"
      :v3 -> "vehicle_status"
    end
  end

  @doc """
  Parses a discovery file of `version` into its `last_updated`, its `ttl`,
  and its feeds, each file's name to its address. A 1.0 or 2.2 file lists
  its feeds under each language it publishes, and `language` names the one
  read; a 3.0 file has one list, and `language` is not read.
  """
  @spec discovery(%{version: version(), document: term(), language: String.t()}) ::
          {:ok, discovery()} | {:error, cause()}
  def discovery(%{version: version, document: document, language: language})
      when is_binary(language) do
    format = format(version)
    feeds_schema = {:map, %{"feeds" => {:list, @feed_schema}}}

    data_schema =
      case format do
        :v3 -> feeds_schema
        _v1_or_v2 -> {:map, %{language => feeds_schema}}
      end

    with :ok <- check(document, schema(format, data_schema)),
         {:ok, header} <- header(format, document) do
      feeds =
        case format do
          :v3 -> document["data"]["feeds"]
          _v1_or_v2 -> document["data"][language]["feeds"]
        end

      {:ok, Map.put(header, :feeds, Map.new(feeds, &{&1["name"], &1["url"]}))}
    end
  end

  @doc """
  Parses a vehicle file of `version`, `free_bike_status` or
  `vehicle_status`, into its `last_updated`, its `ttl`, and its vehicles in
  the order the file lists them. A vehicle's `position` is `nil` when the
  file names neither coordinate, as for a vehicle at a station; a field the
  version does not have, or the file leaves out, is `nil`.
  """
  @spec vehicle_status(%{version: version(), document: term()}) ::
          {:ok, vehicle_status()} | {:error, cause()}
  def vehicle_status(%{version: version, document: document}) do
    format = format(version)
    list_key = vehicle_list_key(format)
    data_schema = {:map, %{list_key => {:list, vehicle_schema(format)}}}

    with :ok <- check(document, schema(format, data_schema)),
         {:ok, header} <- header(format, document),
         {:ok, vehicles} <- vehicles(format, document["data"][list_key]) do
      {:ok, Map.put(header, :vehicles, vehicles)}
    end
  end

  @doc """
  Parses a `vehicle_types` file of `version`, 2.2 or 3.0, into its
  `last_updated`, its `ttl`, and its types in the order the file lists them.
  A type's `form_factor` and `propulsion_type` are the file's strings, whose
  values differ between versions. A type's identifiers are those of the
  vehicle file of the same version alone.
  """
  @spec vehicle_types(%{version: version(), document: term()}) ::
          {:ok, vehicle_types()} | {:error, cause()}
  def vehicle_types(%{version: version, document: document}) do
    Assert.condition(
      version in @vehicle_types_versions,
      "vehicle_types exists in #{inspect(@vehicle_types_versions)}, got: #{inspect(version)}"
    )

    format = format(version)

    type_schema =
      {:map,
       %{
         "vehicle_type_id" => :string,
         "form_factor" => :string,
         "propulsion_type" => :string,
         "max_range_meters" => {:optional, :number}
       }}

    data_schema = {:map, %{"vehicle_types" => {:list, type_schema}}}

    with :ok <- check(document, schema(format, data_schema)),
         {:ok, header} <- header(format, document),
         {:ok, vehicle_types} <- vehicle_types_list(document["data"]["vehicle_types"]) do
      {:ok, Map.put(header, :vehicle_types, vehicle_types)}
    end
  end

  defp format("1.0"), do: :v1
  defp format("2.2"), do: :v2
  defp format("3.0"), do: :v3

  defp format(version) do
    raise Assert.AssertionError,
      message: "GBFS version must be one of #{inspect(@versions)}, got: #{inspect(version)}"
  end

  defp schema(format, data_schema) do
    header_fields =
      case format do
        :v1 -> %{"last_updated" => :integer, "version" => {:optional, :string}}
        :v2 -> %{"last_updated" => :integer, "version" => :string}
        :v3 -> %{"last_updated" => :string, "version" => :string}
      end

    {:map, Map.merge(header_fields, %{"ttl" => :integer, "data" => data_schema})}
  end

  defp check(document, schema) do
    case Schema.mismatch(document, schema) do
      nil -> :ok
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp header(format, %{"last_updated" => last_updated, "ttl" => ttl}) do
    with {:ok, last_updated} <- timestamp(format, last_updated, ["last_updated"]),
         :ok <- at_least_zero(ttl, ["ttl"]) do
      {:ok, %{last_updated: last_updated, ttl: ttl}}
    end
  end

  defp vehicle_list_key(:v3), do: "vehicles"
  defp vehicle_list_key(_v1_or_v2), do: "bikes"

  defp vehicle_id_key(:v3), do: "vehicle_id"
  defp vehicle_id_key(_v1_or_v2), do: "bike_id"

  defp vehicle_schema(:v1) do
    {:map,
     %{
       "bike_id" => :string,
       "lat" => :number,
       "lon" => :number,
       "is_reserved" => :integer,
       "is_disabled" => :integer
     }}
  end

  defp vehicle_schema(format) do
    timestamp_schema =
      case format do
        :v2 -> :integer
        :v3 -> :string
      end

    {:map,
     %{
       vehicle_id_key(format) => :string,
       "lat" => {:optional, :number},
       "lon" => {:optional, :number},
       "is_reserved" => :boolean,
       "is_disabled" => :boolean,
       "vehicle_type_id" => {:optional, :string},
       "current_range_meters" => {:optional, :number},
       "last_reported" => {:optional, timestamp_schema}
     }}
  end

  defp vehicles(format, entries) do
    path = ["data", vehicle_list_key(format)]

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, parsed} ->
      case vehicle(format, entry, path ++ [index]) do
        {:ok, vehicle} -> {:cont, {:ok, [vehicle | parsed]}}
        {:error, cause} -> {:halt, {:error, cause}}
      end
    end)
    |> reverse_parsed()
  end

  defp vehicle(:v1, entry, path) do
    with {:ok, position} <- position(entry, path),
         {:ok, is_disabled} <- flag(entry["is_disabled"], path ++ ["is_disabled"]),
         {:ok, is_reserved} <- flag(entry["is_reserved"], path ++ ["is_reserved"]) do
      {:ok,
       %{
         id: entry["bike_id"],
         position: position,
         vehicle_type_id: nil,
         current_range_meters: nil,
         is_disabled: is_disabled,
         is_reserved: is_reserved,
         last_reported: nil
       }}
    end
  end

  defp vehicle(format, entry, path) do
    with {:ok, position} <- position(entry, path),
         {:ok, last_reported} <- optional_timestamp(format, entry, path ++ ["last_reported"]),
         :ok <- optional_at_least_zero(entry, path ++ ["current_range_meters"]) do
      {:ok,
       %{
         id: entry[vehicle_id_key(format)],
         position: position,
         vehicle_type_id: entry["vehicle_type_id"],
         current_range_meters: entry["current_range_meters"],
         is_disabled: entry["is_disabled"],
         is_reserved: entry["is_reserved"],
         last_reported: last_reported
       }}
    end
  end

  defp vehicle_types_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, parsed} ->
      path = ["data", "vehicle_types", index, "max_range_meters"]

      case optional_at_least_zero(entry, path) do
        :ok -> {:cont, {:ok, [vehicle_type(entry) | parsed]}}
        {:error, cause} -> {:halt, {:error, cause}}
      end
    end)
    |> reverse_parsed()
  end

  defp vehicle_type(entry) do
    %{
      id: entry["vehicle_type_id"],
      form_factor: entry["form_factor"],
      propulsion_type: entry["propulsion_type"],
      max_range_meters: entry["max_range_meters"]
    }
  end

  defp reverse_parsed({:ok, parsed}), do: {:ok, Enum.reverse(parsed)}
  defp reverse_parsed({:error, cause}), do: {:error, cause}

  # A latitude and a longitude come together or not at all: GBFS leaves both
  # out for a vehicle at a station.
  # https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#vehicle_statusjson — checked 2026-11-08
  defp position(entry, path) do
    case {Map.fetch(entry, "lat"), Map.fetch(entry, "lon")} do
      {{:ok, lat}, {:ok, lon}} ->
        coordinates(lat, lon, path)

      {:error, :error} ->
        {:ok, nil}

      {:error, {:ok, _lon}} ->
        {:error, {:schema_mismatch, %{path: path ++ ["lat"], expected: :required}}}

      {{:ok, _lat}, :error} ->
        {:error, {:schema_mismatch, %{path: path ++ ["lon"], expected: :required}}}
    end
  end

  defp coordinates(lat, lon, path) do
    cond do
      abs(lat) > @latitude_max -> {:error, {:out_of_range, path ++ ["lat"]}}
      abs(lon) > @longitude_max -> {:error, {:out_of_range, path ++ ["lon"]}}
      true -> {:ok, %{lat: lat, lon: lon}}
    end
  end

  # GBFS 1.0 writes a flag as the integer 1 or 0.
  # https://github.com/MobilityData/gbfs/blob/v1.0/gbfs.md#free_bike_statusjson — checked 2026-11-08
  defp flag(1, _path), do: {:ok, true}
  defp flag(0, _path), do: {:ok, false}
  defp flag(_value, path), do: {:error, {:out_of_range, path}}

  defp optional_timestamp(format, entry, path) do
    case Map.fetch(entry, List.last(path)) do
      {:ok, value} -> timestamp(format, value, path)
      :error -> {:ok, nil}
    end
  end

  # GBFS 3.0 writes a timestamp as an RFC 3339 string, the versions before it
  # as POSIX seconds.
  # https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#field-types — checked 2026-11-08
  # https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md#field-types — checked 2026-11-08
  defp timestamp(:v3, value, path) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset_seconds} -> {:ok, timestamp}
      {:error, _reason} -> {:error, {:invalid_timestamp, path}}
    end
  end

  defp timestamp(_v1_or_v2, value, path) do
    case DateTime.from_unix(value) do
      {:ok, timestamp} -> {:ok, timestamp}
      {:error, _reason} -> {:error, {:invalid_timestamp, path}}
    end
  end

  defp optional_at_least_zero(entry, path) do
    case Map.fetch(entry, List.last(path)) do
      {:ok, value} -> at_least_zero(value, path)
      :error -> :ok
    end
  end

  defp at_least_zero(value, _path) when value >= 0, do: :ok
  defp at_least_zero(_value, path), do: {:error, {:out_of_range, path}}
end
