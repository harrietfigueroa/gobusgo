defmodule Gobusgo.Basemap.Manifest do
  @agency_count_max 1_000
  @archive_count_max 99

  @moduledoc """
  The manifest an extraction writes beside its archives, read back: which
  archives exist, the bounds of each, and the archive and the coverage
  bounds of each agency. Everything here is pure.

  `decode/1` takes the text `Gobusgo.Basemap.ExtractPlan.manifest/1`
  produces and accepts at most #{@archive_count_max} archives and
  #{@agency_count_max} agencies. An archive's name has the form
  `basemap-<snapshot>-<number>.pmtiles`, and every agency names an archive
  the manifest holds.
  """

  alias Gobusgo.Schema

  @archive_name_pattern ~r/\Abasemap-[0-9]{8}-[0-9]{2}\.pmtiles\z/

  @bounds_schema {:map,
                  %{"south" => :number, "west" => :number, "north" => :number, "east" => :number}}
  @schema {:map,
           %{
             "snapshot" => :string,
             "archives" => {:list, {:map, %{"name" => :string, "bounds" => @bounds_schema}}},
             "agencies" =>
               {:list,
                {:map, %{"agencyId" => :string, "archive" => :string, "bounds" => @bounds_schema}}}
           }}

  @type bounds :: %{south: number(), west: number(), north: number(), east: number()}
  @type archive :: %{name: String.t(), bounds: bounds()}
  @type agency :: %{agency_id: String.t(), archive: String.t(), bounds: bounds()}
  @type t :: %{snapshot: String.t(), archives: [archive(), ...], agencies: [agency()]}
  @type decode_error ::
          :invalid_json
          | {:schema_mismatch, Schema.mismatch()}
          | :no_archive
          | {:archive_count_exceeded, pos_integer()}
          | {:agency_count_exceeded, pos_integer()}
          | {:invalid_archive_name, String.t()}
          | {:unknown_archive, String.t()}

  @doc "Returns the manifest that `content` holds, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, t()} | {:error, decode_error()}
  def decode(content) when is_binary(content) do
    with {:ok, decoded} <- decode_json(content),
         nil <- Schema.mismatch(decoded, @schema),
         manifest = manifest(decoded),
         :ok <- check(manifest) do
      {:ok, manifest}
    else
      %{path: _path} = mismatch -> {:error, {:schema_mismatch, mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the archive named `name`, or `:error` when the manifest has none."
  @spec fetch_archive(t(), String.t()) :: {:ok, archive()} | :error
  def fetch_archive(%{archives: archives}, name) when is_binary(name) do
    case Enum.find(archives, &(&1.name == name)) do
      nil -> :error
      archive -> {:ok, archive}
    end
  end

  @doc "Returns the agency `agency_id`, or `:error` when the manifest has none."
  @spec fetch_agency(t(), String.t()) :: {:ok, agency()} | :error
  def fetch_agency(%{agencies: agencies}, agency_id) when is_binary(agency_id) do
    case Enum.find(agencies, &(&1.agency_id == agency_id)) do
      nil -> :error
      agency -> {:ok, agency}
    end
  end

  defp decode_json(content) do
    case JSON.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp manifest(decoded) do
    %{
      snapshot: decoded["snapshot"],
      archives: Enum.map(decoded["archives"], &%{name: &1["name"], bounds: bounds(&1["bounds"])}),
      agencies:
        Enum.map(
          decoded["agencies"],
          &%{agency_id: &1["agencyId"], archive: &1["archive"], bounds: bounds(&1["bounds"])}
        )
    }
  end

  defp bounds(%{"south" => south, "west" => west, "north" => north, "east" => east}) do
    %{south: south, west: west, north: north, east: east}
  end

  defp check(%{archives: archives, agencies: agencies}) do
    archive_count = length(archives)
    agency_count = length(agencies)
    names = Enum.map(archives, & &1.name)

    cond do
      archive_count == 0 ->
        {:error, :no_archive}

      archive_count > @archive_count_max ->
        {:error, {:archive_count_exceeded, archive_count}}

      agency_count > @agency_count_max ->
        {:error, {:agency_count_exceeded, agency_count}}

      invalid = Enum.find(names, &(not (&1 =~ @archive_name_pattern))) ->
        {:error, {:invalid_archive_name, invalid}}

      unknown = Enum.find(agencies, &(&1.archive not in names)) ->
        {:error, {:unknown_archive, unknown.archive}}

      true ->
        :ok
    end
  end
end
