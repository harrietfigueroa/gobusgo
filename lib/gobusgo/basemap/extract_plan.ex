defmodule Gobusgo.Basemap.ExtractPlan do
  @archive_count_max 99
  @buffer_meters 5_000
  # The daily builds and their zooms:
  # https://docs.protomaps.com/basemaps/downloads — checked 2026-10-04
  @source_base_url "https://build.protomaps.com"
  @zoom_min 0
  @zoom_max 15

  @moduledoc """
  The plan of one basemap extraction: which regional archives the coverage
  of a list of agencies needs, cut from which Protomaps build. Everything
  here is pure.

  A plan holds one archive per region of
  `Gobusgo.OneBusAway.AgencyCoverage.extract_regions/2`, with every agency's
  coverage widened by #{@buffer_meters} meters, so agencies whose coverage
  overlaps share one archive. An archive is named
  `basemap-<snapshot>-<number>.pmtiles`, numbered from `01` in region order,
  and a plan holds at most #{@archive_count_max} archives.

  The source is the Protomaps daily build of the snapshot, a date written
  `YYYYMMDD`, at `#{@source_base_url}/<snapshot>.pmtiles`. A build holds the
  zooms #{@zoom_min} to #{@zoom_max}, and an archive keeps all of them.

  A plan given an offline zoom bound also holds, for each archive, an
  offline extract of it that keeps the zooms #{@zoom_min} to that bound and
  the whole of its area, the copy a browser saves for offline use. It is
  named `basemap-<snapshot>-<number>-z<bound>.pmtiles` and cut from the
  extracted archive, so it asks the build for nothing more.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyCoverage

  @snapshot_pattern ~r/\A[0-9]{8}\z/
  @archive_number_width 2

  @type offline :: %{name: String.t(), zoom_max: non_neg_integer()}
  @type archive :: %{
          name: String.t(),
          agency_ids: [String.t(), ...],
          bounds: AgencyCoverage.bounds(),
          offline: offline() | nil
        }
  @type t :: %{
          snapshot: String.t(),
          source_url: String.t(),
          zoom_min: non_neg_integer(),
          zoom_max: pos_integer(),
          buffer_meters: non_neg_integer(),
          archives: [archive()],
          agencies: [
            %{agency_id: String.t(), archive: String.t(), bounds: AgencyCoverage.bounds()}
          ],
          skipped: [%{agency_id: String.t(), reason: AgencyCoverage.coverage_error()}]
        }

  @doc "Returns whether `snapshot` is a build date written `YYYYMMDD`."
  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(snapshot) when is_binary(snapshot), do: snapshot =~ @snapshot_pattern
  def valid_snapshot?(_snapshot), do: false

  @doc """
  Returns whether `zoom` can bound an offline extract: an integer from
  #{@zoom_min} up to and not including the archives' highest zoom,
  #{@zoom_max}.
  """
  @spec valid_offline_zoom_max?(term()) :: boolean()
  def valid_offline_zoom_max?(zoom) when is_integer(zoom),
    do: zoom >= @zoom_min and zoom < @zoom_max

  def valid_offline_zoom_max?(_zoom), do: false

  @doc """
  Returns the plan for `agencies` and the build of `snapshot`, with an
  offline extract of each archive up to `offline_zoom_max`, or none for
  `nil`. The caller guarantees `valid_snapshot?/1` for the snapshot and
  `valid_offline_zoom_max?/1` for a bound.
  """
  @spec build(%{
          agencies: [AgencyCoverage.agency()],
          snapshot: String.t(),
          offline_zoom_max: non_neg_integer() | nil
        }) :: t()
  def build(%{agencies: agencies, snapshot: snapshot, offline_zoom_max: offline_zoom_max})
      when is_list(agencies) do
    Assert.condition(
      valid_snapshot?(snapshot),
      "snapshot must be a date written YYYYMMDD, got: #{inspect(snapshot)}"
    )

    if offline_zoom_max != nil do
      Assert.condition(
        valid_offline_zoom_max?(offline_zoom_max),
        "offline zoom bound must be an integer from #{@zoom_min} below #{@zoom_max}, " <>
          "got: #{inspect(offline_zoom_max)}"
      )
    end

    %{regions: regions, agencies: located, skipped: skipped} =
      AgencyCoverage.extract_regions(agencies, @buffer_meters)

    archive_count = length(regions)

    Assert.condition(
      archive_count <= @archive_count_max,
      "archive count #{archive_count} exceeds #{@archive_count_max}"
    )

    archives =
      for {%{agency_ids: agency_ids, bounds: bounds}, index} <- Enum.with_index(regions) do
        number = index + 1

        %{
          name: archive_name(snapshot, number),
          agency_ids: agency_ids,
          bounds: bounds,
          offline: offline(%{snapshot: snapshot, number: number, zoom_max: offline_zoom_max})
        }
      end

    archive_by_agency_id =
      for %{name: name, agency_ids: agency_ids} <- archives, agency_id <- agency_ids, into: %{} do
        {agency_id, name}
      end

    %{
      snapshot: snapshot,
      source_url: "#{@source_base_url}/#{snapshot}.pmtiles",
      zoom_min: @zoom_min,
      zoom_max: @zoom_max,
      buffer_meters: @buffer_meters,
      archives: archives,
      agencies:
        for %{agency_id: agency_id, bounds: bounds} <- located do
          %{
            agency_id: agency_id,
            archive: Map.fetch!(archive_by_agency_id, agency_id),
            bounds: bounds
          }
        end,
      skipped: skipped
    }
  end

  @doc """
  Returns the arguments of the `pmtiles` command that cuts `archive` of
  `plan` into the file at `output_path`.
  """
  @spec extract_arguments(%{plan: t(), archive: archive(), output_path: String.t()}) ::
          [String.t(), ...]
  def extract_arguments(%{
        plan: %{source_url: source_url, zoom_max: zoom_max},
        archive: %{bounds: bounds},
        output_path: output_path
      })
      when is_binary(output_path) do
    # https://docs.protomaps.com/pmtiles/cli — checked 2026-10-04. The box is
    # MIN_LON,MIN_LAT,MAX_LON,MAX_LAT.
    [
      "extract",
      source_url,
      output_path,
      "--bbox=#{bounds.west},#{bounds.south},#{bounds.east},#{bounds.north}",
      "--maxzoom=#{zoom_max}"
    ]
  end

  @doc """
  Returns the arguments of the `pmtiles` command that cuts the offline
  extract `offline` out of the extracted archive at `archive_path` into the
  file at `output_path`. With no box the extract keeps the archive's whole
  area.
  """
  @spec offline_extract_arguments(%{
          offline: offline(),
          archive_path: String.t(),
          output_path: String.t()
        }) :: [String.t(), ...]
  def offline_extract_arguments(%{
        offline: %{zoom_max: zoom_max},
        archive_path: archive_path,
        output_path: output_path
      })
      when is_binary(archive_path) and is_binary(output_path) do
    # https://docs.protomaps.com/pmtiles/cli — checked 2026-11-08. The input
    # is a local or a remote archive.
    ["extract", archive_path, output_path, "--maxzoom=#{zoom_max}"]
  end

  @doc """
  Returns the manifest of a finished extraction as a map ready for JSON:
  the source, the zoom range, every archive of `plan` and its offline
  extract, where the plan has one, each with its size from
  `archive_bytes`, the archive and the bounds of every agency, and the
  skipped agencies. `response_destination` names the stored agency response
  the agencies come from.
  """
  @spec manifest(%{
          plan: t(),
          archive_bytes: %{String.t() => non_neg_integer()},
          response_destination: String.t()
        }) :: %{String.t() => term()}
  def manifest(%{plan: plan, archive_bytes: archive_bytes, response_destination: destination})
      when is_map(archive_bytes) and is_binary(destination) do
    %{
      "snapshot" => plan.snapshot,
      "sourceUrl" => plan.source_url,
      "sourceResponse" => destination,
      "zoomMin" => plan.zoom_min,
      "zoomMax" => plan.zoom_max,
      "bufferMeters" => plan.buffer_meters,
      "archives" =>
        for %{name: name, agency_ids: agency_ids, bounds: bounds, offline: offline} <-
              plan.archives do
          manifest_archive(%{
            name: name,
            agency_ids: agency_ids,
            bounds: bounds,
            offline: offline,
            archive_bytes: archive_bytes
          })
        end,
      "agencies" =>
        for %{agency_id: agency_id, archive: archive, bounds: bounds} <- plan.agencies do
          %{"agencyId" => agency_id, "archive" => archive, "bounds" => manifest_bounds(bounds)}
        end,
      "skipped" =>
        for %{agency_id: agency_id, reason: reason} <- plan.skipped do
          %{"agencyId" => agency_id, "reason" => manifest_reason(reason)}
        end
    }
  end

  defp archive_name(snapshot, number) do
    "basemap-#{snapshot}-#{padded_number(number)}.pmtiles"
  end

  defp padded_number(number) do
    number |> Integer.to_string() |> String.pad_leading(@archive_number_width, "0")
  end

  defp offline(%{zoom_max: nil}), do: nil

  defp offline(%{snapshot: snapshot, number: number, zoom_max: zoom_max}) do
    %{
      name: "basemap-#{snapshot}-#{padded_number(number)}-z#{zoom_max}.pmtiles",
      zoom_max: zoom_max
    }
  end

  defp manifest_archive(%{name: name, archive_bytes: archive_bytes} = archive) do
    entry = %{
      "name" => name,
      "bytes" => fetch_bytes(archive_bytes, name),
      "agencyIds" => archive.agency_ids,
      "bounds" => manifest_bounds(archive.bounds)
    }

    case archive.offline do
      nil ->
        entry

      %{name: offline_name, zoom_max: zoom_max} ->
        offline_entry = %{
          "name" => offline_name,
          "bytes" => fetch_bytes(archive_bytes, offline_name),
          "zoomMax" => zoom_max
        }

        Map.put(entry, "offline", offline_entry)
    end
  end

  defp fetch_bytes(archive_bytes, name) do
    Assert.condition(is_map_key(archive_bytes, name), "archive #{name} has no size")
    Map.fetch!(archive_bytes, name)
  end

  defp manifest_bounds(%{south: south, west: west, north: north, east: east}) do
    %{"south" => south, "west" => west, "north" => north, "east" => east}
  end

  defp manifest_reason(:coverage_missing), do: "coverage_missing"
  defp manifest_reason({:coverage_invalid, field}), do: "coverage_invalid:#{field}"
end
