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
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyCoverage

  @snapshot_pattern ~r/\A[0-9]{8}\z/
  @archive_number_width 2

  @type archive :: %{
          name: String.t(),
          agency_ids: [String.t(), ...],
          bounds: AgencyCoverage.bounds()
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
  Returns the plan for `agencies` and the build of `snapshot`. The caller
  guarantees `valid_snapshot?/1` for the snapshot.
  """
  @spec build(%{agencies: [AgencyCoverage.agency()], snapshot: String.t()}) :: t()
  def build(%{agencies: agencies, snapshot: snapshot}) when is_list(agencies) do
    Assert.condition(
      valid_snapshot?(snapshot),
      "snapshot must be a date written YYYYMMDD, got: #{inspect(snapshot)}"
    )

    %{regions: regions, agencies: located, skipped: skipped} =
      AgencyCoverage.extract_regions(agencies, @buffer_meters)

    archive_count = length(regions)

    Assert.condition(
      archive_count <= @archive_count_max,
      "archive count #{archive_count} exceeds #{@archive_count_max}"
    )

    archives =
      for {%{agency_ids: agency_ids, bounds: bounds}, index} <- Enum.with_index(regions) do
        %{name: archive_name(snapshot, index + 1), agency_ids: agency_ids, bounds: bounds}
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
  Returns the manifest of a finished extraction as a map ready for JSON:
  the source, the zoom range, every archive of `plan` with its size from
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
        for %{name: name, agency_ids: agency_ids, bounds: bounds} <- plan.archives do
          Assert.condition(is_map_key(archive_bytes, name), "archive #{name} has no size")

          %{
            "name" => name,
            "bytes" => Map.fetch!(archive_bytes, name),
            "agencyIds" => agency_ids,
            "bounds" => manifest_bounds(bounds)
          }
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
    padded = number |> Integer.to_string() |> String.pad_leading(@archive_number_width, "0")
    "basemap-#{snapshot}-#{padded}.pmtiles"
  end

  defp manifest_bounds(%{south: south, west: west, north: north, east: east}) do
    %{"south" => south, "west" => west, "north" => north, "east" => east}
  end

  defp manifest_reason(:coverage_missing), do: "coverage_missing"
  defp manifest_reason({:coverage_invalid, field}), do: "coverage_invalid:#{field}"
end
