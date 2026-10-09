defmodule GobusgoWeb.BasemapSources do
  @moduledoc """
  Where a map page loads its basemap from: the address of an archive, of the
  fonts, and of the sprites, and the attribution the map has to show; and
  the view a page opens the map with. Everything here is pure, and nothing
  here is about vehicles.

  The archives are served under `/basemap` and the fonts and sprites under
  `/vendor/basemaps-assets`, the vendored archive of that name.
  """

  @archive_path "/basemap"
  @fonts_path "/vendor/basemaps-assets/fonts"
  @sprites_path "/vendor/basemaps-assets/sprites/v4"

  # The basemap is an Open Database License produced work, so a map that
  # shows it credits OpenStreetMap.
  # https://docs.protomaps.com/basemaps/downloads — checked 2026-10-04
  @attribution ~s(<a href="https://www.openstreetmap.org/copyright">&copy; OpenStreetMap</a>)

  alias Gobusgo.Basemap.Manifest

  @type t :: %{
          archive_url: String.t(),
          fonts_url: String.t(),
          sprites_url: String.t(),
          attribution: String.t()
        }

  @doc "Returns the sources of a map drawn from the archive named `archive_name`."
  @spec sources(String.t()) :: t()
  def sources(archive_name) when is_binary(archive_name) do
    %{
      archive_url: "#{@archive_path}/#{archive_name}",
      fonts_url: @fonts_path,
      sprites_url: @sprites_path,
      attribution: @attribution
    }
  end

  @typedoc """
  The map a page shows: the archive it is drawn from, its sources, the
  bounds the view fits, the bounds of the whole archive, the agency the
  fitted bounds belong to or `nil` for the whole archive, and the agencies a
  view can be chosen for.
  """
  @type view :: %{
          archive: String.t(),
          sources: t(),
          bounds: Manifest.bounds(),
          archive_bounds: Manifest.bounds(),
          agency_id: String.t() | nil,
          agency_ids: [String.t()]
        }

  @doc """
  Returns the map for `agency_id` out of `manifest`: the archive that holds
  the agency, fitted to the agency's own coverage. For `nil`, and for an
  agency the manifest does not hold, it is the manifest's first archive,
  fitted to all of it.
  """
  @spec view(Manifest.t(), String.t() | nil) :: view()
  def view(%{archives: [first_archive | _rest], agencies: agencies} = manifest, agency_id) do
    selected =
      case agency_id do
        nil -> :error
        agency_id -> Manifest.fetch_agency(manifest, agency_id)
      end

    {archive, bounds, selected_id} =
      case selected do
        {:ok, agency} -> {agency.archive, agency.bounds, agency.agency_id}
        :error -> {first_archive.name, first_archive.bounds, nil}
      end

    {:ok, %{bounds: archive_bounds}} = Manifest.fetch_archive(manifest, archive)

    %{
      archive: archive,
      sources: sources(archive),
      bounds: bounds,
      archive_bounds: archive_bounds,
      agency_id: selected_id,
      agency_ids: Enum.map(agencies, & &1.agency_id)
    }
  end

  @doc """
  Returns `view` fitted to `bounds`, bounds inside its archive that belong
  to no agency.
  """
  @spec fitted(view(), Manifest.bounds()) :: view()
  def fitted(%{archive: _archive} = view, %{south: _, west: _, north: _, east: _} = bounds) do
    %{view | bounds: bounds, agency_id: nil}
  end
end
