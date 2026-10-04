defmodule Gobusgo.Basemap.ManifestTest do
  # Verifies the manifest reader as pure functions: the manifest that
  # ExtractPlan.manifest/1 writes is read back, and each rule a manifest has
  # to obey is reported for text that breaks it.
  use ExUnit.Case, async: true

  alias Gobusgo.Basemap.ExtractPlan
  alias Gobusgo.Basemap.Manifest
  alias Gobusgo.CanonicalJson

  @archive "basemap-20261004-01.pmtiles"
  @bounds %{"south" => 46.9, "west" => -123.1, "north" => 48.6, "east" => -121.5}
  @decoded %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => @archive, "bounds" => @bounds}],
    "agencies" => [
      %{
        "agencyId" => "1",
        "archive" => @archive,
        "bounds" => %{"south" => 47.2, "west" => -122.5, "north" => 47.9, "east" => -121.8}
      }
    ]
  }

  defp text(changes), do: JSON.encode!(Map.merge(@decoded, changes))

  describe "decode/1" do
    test "reads the archives and the agencies with their bounds" do
      assert Manifest.decode(text(%{})) ==
               {:ok,
                %{
                  snapshot: "20261004",
                  archives: [
                    %{
                      name: @archive,
                      bounds: %{south: 46.9, west: -123.1, north: 48.6, east: -121.5}
                    }
                  ],
                  agencies: [
                    %{
                      agency_id: "1",
                      archive: @archive,
                      bounds: %{south: 47.2, west: -122.5, north: 47.9, east: -121.8}
                    }
                  ]
                }}
    end

    test "reads the manifest an extraction writes" do
      plan =
        ExtractPlan.build(%{
          agencies: [
            %{id: "1", coverage: %{lat: 47.5, lon: -122.0, lat_span: 1.0, lon_span: 0.5}}
          ],
          snapshot: "20261004"
        })

      written =
        ExtractPlan.manifest(%{
          plan: plan,
          archive_bytes: %{@archive => 10},
          response_destination: "a"
        })

      assert {:ok,
              %{archives: [%{name: @archive}], agencies: [%{agency_id: "1", archive: @archive}]}} =
               written |> CanonicalJson.encode() |> Manifest.decode()
    end

    test "returns :invalid_json for text that is not JSON" do
      assert Manifest.decode("not json") == {:error, :invalid_json}
    end

    test "returns the mismatch for JSON that is not a manifest" do
      assert {:error, {:schema_mismatch, %{path: ["archives"]}}} =
               Manifest.decode(text(%{"archives" => 1}))
    end

    test "returns :no_archive for a manifest without one" do
      assert Manifest.decode(text(%{"archives" => [], "agencies" => []})) == {:error, :no_archive}
    end

    for name <- [
          "../secret.pmtiles",
          "basemap-latest-01.pmtiles",
          "basemap-20261004-01.pmtiles.partial"
        ] do
      test "returns the archive name #{name} as invalid" do
        archives = [%{"name" => unquote(name), "bounds" => @bounds}]

        assert Manifest.decode(text(%{"archives" => archives, "agencies" => []})) ==
                 {:error, {:invalid_archive_name, unquote(name)}}
      end
    end

    test "returns the archive an agency names and the manifest does not hold" do
      agencies = [
        %{"agencyId" => "1", "archive" => "basemap-20261004-02.pmtiles", "bounds" => @bounds}
      ]

      assert Manifest.decode(text(%{"agencies" => agencies})) ==
               {:error, {:unknown_archive, "basemap-20261004-02.pmtiles"}}
    end

    test "returns the count of more archives than the bound" do
      archives =
        for number <- 1..100 do
          padded = number |> Integer.to_string() |> String.pad_leading(3, "0")
          %{"name" => "basemap-20261004-#{padded}.pmtiles", "bounds" => @bounds}
        end

      assert Manifest.decode(text(%{"archives" => archives, "agencies" => []})) ==
               {:error, {:archive_count_exceeded, 100}}
    end

    test "returns the count of more agencies than the bound" do
      agencies =
        for number <- 1..1_001,
            do: %{"agencyId" => "#{number}", "archive" => @archive, "bounds" => @bounds}

      assert Manifest.decode(text(%{"agencies" => agencies})) ==
               {:error, {:agency_count_exceeded, 1_001}}
    end
  end

  describe "fetch_agency/2 and fetch_archive/2" do
    setup do
      {:ok, manifest} = Manifest.decode(text(%{}))
      %{manifest: manifest}
    end

    test "return the agency and the archive by their identifiers", %{manifest: manifest} do
      assert {:ok, %{agency_id: "1", archive: @archive}} = Manifest.fetch_agency(manifest, "1")
      assert {:ok, %{name: @archive}} = Manifest.fetch_archive(manifest, @archive)
    end

    test "return :error for an identifier the manifest does not hold", %{manifest: manifest} do
      assert Manifest.fetch_agency(manifest, "6289") == :error
      assert Manifest.fetch_archive(manifest, "basemap-20261004-02.pmtiles") == :error
    end
  end
end
