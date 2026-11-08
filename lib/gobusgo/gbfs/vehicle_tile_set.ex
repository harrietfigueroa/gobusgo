defmodule Gobusgo.Gbfs.VehicleTileSet do
  @prefix "shared-vehicles"
  @system_segment_prefix "system="
  @tile_zoom 14
  @tile_count_max 4_096
  @hash_prefix_size 16
  @index_format_version 1
  @microdegrees_per_degree 1_000_000

  @moduledoc """
  The files that publish one fetch of a GBFS system's shared vehicles to
  the browser: one tile per Web Mercator tile of zoom #{@tile_zoom} that
  holds a vehicle, one whole-city file that holds every vehicle, and an
  index that names them. Everything here is pure, so the files are a
  function of the fetch and the vehicle types alone.

  A vehicle is published where its file gives it a position and it is
  neither disabled nor reserved, since a rider can take no other. Its form
  factor comes from `Gobusgo.Gbfs.VehicleForms.lookup/2`, and its range
  from the file's `current_range_meters`. A tile and the whole-city file are blocks of
  `Gobusgo.Gbfs.VehicleTileFormat`, a tile stored to its own bounds and the
  whole-city file to the box around every published vehicle, so a reader
  decodes both alike. No file holds a vehicle identifier.

  ## Destinations

  Every file of a fetch is in the fetch's own directory:

      #{@prefix}/dt=YYYY-MM-DD/#{@system_segment_prefix}<system>/<fetchedAt>_<requestId>/

  with `dt` the UTC date of the fetch time and `fetchedAt` the fetch time in
  UTC basic ISO 8601, as `Gobusgo.Gbfs.RawVehicleStatus` names its files,
  so the fetch a file belongs to is read from its destination alone. Each
  file's name ends in the first #{@hash_prefix_size} hexadecimal characters
  of the SHA-256 of its content, so an address never holds other content:

    * `tile-#{@tile_zoom}-<x>-<y>-<hash>.bin.gz`, a tile;
    * `city-<hash>.bin.gz`, the whole-city file;
    * `index-<hash>.json.gz`, the index.

  The `.gz` ending has the writer store the content compressed, and the
  reader of the published file expands it.

  ## Index

  JSON with sorted keys: `formatVersion` #{@index_format_version},
  `systemId`, `version`, `fetchedAt` and `lastUpdated` in UTC extended ISO
  8601, `vehicleCount`, `city`, the whole-city file's name, `tileZoom`
  #{@tile_zoom}, and `tiles`, one entry per tile in `x` then `y` order as
  `[x, y, count, hash]`, whose file is named from them as above. A tile the
  index does not list holds no vehicle.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Destination
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleForms
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleTileFormat
  alias Gobusgo.RequestId

  @bin_extension ".bin" <> Compression.suffix()
  @json_extension ".json" <> Compression.suffix()

  @type file :: %{destination: String.t(), content: binary()}

  @type t :: %{
          files: [file()],
          index: file(),
          tile_count: non_neg_integer(),
          vehicle_count: non_neg_integer()
        }

  @typedoc "What a destination of this dataset names."
  @type named :: %{system_id: String.t(), fetched_at: DateTime.t(), request_id: RequestId.t()}

  @type tile :: %{x: non_neg_integer(), y: non_neg_integer()}

  @doc "The prefix every destination of this dataset starts with, without a trailing `/`."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The zoom of every tile."
  @spec tile_zoom() :: pos_integer()
  def tile_zoom, do: @tile_zoom

  @doc "The prefix of the destinations of `system_id` fetched on `date`, ending in `/`."
  @spec partition_prefix(String.t(), Date.t()) :: String.t()
  def partition_prefix(system_id, %Date{} = date) do
    Systems.assert_id(system_id)

    Enum.join([@prefix, "dt=" <> Date.to_iso8601(date), @system_segment_prefix <> system_id], "/") <>
      "/"
  end

  @doc """
  Returns the files of `input.fetched`, a fetch as
  `Gobusgo.Gbfs.VehicleStatusBatch.Records.decode/1` returns it, with the
  form factors of `input.type_fetches`, the current fetches of the vehicle
  type view. Raises `Gobusgo.Assert.AssertionError` for a fetch whose
  vehicles fill more than #{@tile_count_max} tiles.
  """
  @spec build(%{fetched: Records.fetched(), type_fetches: [map()]}) :: t()
  def build(%{fetched: %{kind: :fetched} = fetched, type_fetches: type_fetches})
      when is_list(type_fetches) do
    %{id: system_id, request_id: request_id, fetched_at: %DateTime{} = fetched_at} = fetched
    Systems.assert_id(system_id)
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    directory = directory(%{system_id: system_id, fetched_at: fetched_at, request_id: request_id})
    vehicles = published_vehicles(%{fetched: fetched, type_fetches: type_fetches})

    tiles =
      vehicles
      |> Enum.group_by(&tile_of/1)
      |> Enum.sort_by(fn {%{x: x, y: y}, _vehicles} -> {x, y} end)

    tile_count = length(tiles)

    Assert.condition(
      tile_count <= @tile_count_max,
      "a fetch must fill at most #{@tile_count_max} tiles, got: #{tile_count}"
    )

    tile_files =
      Enum.map(tiles, fn {tile, tile_vehicles} ->
        content = VehicleTileFormat.encode(%{bounds: tile_bounds(tile), vehicles: tile_vehicles})
        hash = hash_prefix(content)
        name = "tile-#{@tile_zoom}-#{tile.x}-#{tile.y}-#{hash}" <> @bin_extension

        %{
          entry: [tile.x, tile.y, length(tile_vehicles), hash],
          file: %{destination: directory <> name, content: content}
        }
      end)

    city_content = VehicleTileFormat.encode(%{bounds: city_bounds(vehicles), vehicles: vehicles})
    city_name = "city-" <> hash_prefix(city_content) <> @bin_extension
    city = %{destination: directory <> city_name, content: city_content}

    index_content =
      CanonicalJson.encode(%{
        "formatVersion" => @index_format_version,
        "systemId" => system_id,
        "version" => fetched.version,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "lastUpdated" => DateTime.to_iso8601(fetched.last_updated, :extended),
        "vehicleCount" => length(vehicles),
        "city" => city_name,
        "tileZoom" => @tile_zoom,
        "tiles" => Enum.map(tile_files, & &1.entry)
      })

    index = %{
      destination: directory <> "index-" <> hash_prefix(index_content) <> @json_extension,
      content: index_content
    }

    files = Enum.map(tile_files, & &1.file) ++ [city]
    Enum.each([index | files], &assert_destination/1)

    %{files: files, index: index, tile_count: tile_count, vehicle_count: length(vehicles)}
  end

  @doc """
  Returns the fetch `destination` belongs to, or `:error` for a destination
  that is not one `build/1` produces.
  """
  @spec parse_destination(String.t()) :: {:ok, named()} | :error
  def parse_destination(destination) when is_binary(destination) do
    with [@prefix, "dt=" <> date_text, @system_segment_prefix <> system_id, fetch, name] <-
           String.split(destination, "/"),
         {:ok, date} <- Date.from_iso8601(date_text),
         true <- Systems.id?(system_id),
         [stamp, request_id] <- String.split(fetch, "_"),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(stamp, :basic),
         true <- RequestId.valid?(request_id),
         true <- DateTime.to_date(fetched_at) == date,
         true <- file_name?(name) do
      {:ok, %{system_id: system_id, fetched_at: fetched_at, request_id: request_id}}
    else
      _other -> :error
    end
  end

  @doc "The tile of zoom #{@tile_zoom} that holds the position `lat`, `lon`."
  @spec tile_of(%{lat: number(), lon: number()}) :: tile()
  def tile_of(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon) do
    tile_count = Integer.pow(2, @tile_zoom)
    lat_radians = lat * :math.pi() / 180
    mercator = :math.log(:math.tan(lat_radians) + 1 / :math.cos(lat_radians))
    x = floor((lon + 180) / 360 * tile_count)
    y = floor((1 - mercator / :math.pi()) / 2 * tile_count)
    %{x: clamp_tile(x, tile_count), y: clamp_tile(y, tile_count)}
  end

  @doc "The bounds of `tile`, in millionths of a degree."
  @spec tile_bounds(tile()) :: VehicleTileFormat.bounds()
  def tile_bounds(%{x: x, y: y}) do
    tile_count = Integer.pow(2, @tile_zoom)

    %{
      south_microdegrees: VehicleTileFormat.microdegrees(tile_lat(y + 1, tile_count)),
      west_microdegrees: VehicleTileFormat.microdegrees(x / tile_count * 360 - 180),
      north_microdegrees: VehicleTileFormat.microdegrees(tile_lat(y, tile_count)),
      east_microdegrees: VehicleTileFormat.microdegrees((x + 1) / tile_count * 360 - 180)
    }
  end

  defp tile_lat(y, tile_count) do
    :math.atan(:math.sinh(:math.pi() * (1 - 2 * y / tile_count))) * 180 / :math.pi()
  end

  defp clamp_tile(index, _tile_count) when index < 0, do: 0
  defp clamp_tile(index, tile_count) when index >= tile_count, do: tile_count - 1
  defp clamp_tile(index, _tile_count), do: index

  defp directory(%{system_id: system_id, fetched_at: fetched_at, request_id: request_id}) do
    fetched_at = DateTime.truncate(fetched_at, :second)
    stamp = DateTime.to_iso8601(fetched_at, :basic)
    partition_prefix(system_id, DateTime.to_date(fetched_at)) <> stamp <> "_" <> request_id <> "/"
  end

  defp published_vehicles(%{fetched: fetched, type_fetches: type_fetches}) do
    for %{position: %{lat: lat, lon: lon}, is_disabled: false, is_reserved: false} = vehicle <-
          fetched.vehicles do
      form =
        VehicleForms.lookup(type_fetches, %{
          system_id: fetched.id,
          version: fetched.version,
          vehicle_type_id: vehicle.vehicle_type_id
        })

      %{
        lat: lat,
        lon: lon,
        current_range_meters: vehicle.current_range_meters,
        form_factor: form.form_factor
      }
    end
  end

  # The box around every vehicle, rounded outward to whole microdegrees, or
  # an empty box at the origin for a fetch with none.
  defp city_bounds([]) do
    %{south_microdegrees: 0, west_microdegrees: 0, north_microdegrees: 0, east_microdegrees: 0}
  end

  defp city_bounds(vehicles) do
    {lat_min, lat_max} = vehicles |> Enum.map(& &1.lat) |> Enum.min_max()
    {lon_min, lon_max} = vehicles |> Enum.map(& &1.lon) |> Enum.min_max()

    %{
      south_microdegrees: floor(lat_min * @microdegrees_per_degree),
      west_microdegrees: floor(lon_min * @microdegrees_per_degree),
      north_microdegrees: ceil(lat_max * @microdegrees_per_degree),
      east_microdegrees: ceil(lon_max * @microdegrees_per_degree)
    }
  end

  defp hash_prefix(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_prefix_size)
  end

  defp file_name?(name) do
    String.ends_with?(name, @bin_extension) or String.ends_with?(name, @json_extension)
  end

  defp assert_destination(%{destination: destination}) do
    Assert.condition(
      match?({:ok, _segments}, Destination.validate(destination)),
      "built an invalid destination: #{destination}"
    )

    Assert.condition(
      match?({:ok, _named}, parse_destination(destination)),
      "built an unreadable destination: #{destination}"
    )
  end
end
