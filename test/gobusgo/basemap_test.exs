defmodule Gobusgo.BasemapTest do
  # Reads manifests out of the test's temporary directory and observes what
  # read_manifest/1 returns for a directory with a manifest, without one, and
  # with one that cannot be used.
  use ExUnit.Case, async: true

  alias Gobusgo.Basemap

  @moduletag :tmp_dir

  @manifest JSON.encode!(%{
              "snapshot" => "20261004",
              "archives" => [
                %{
                  "name" => "basemap-20261004-01.pmtiles",
                  "bounds" => %{
                    "south" => 46.9,
                    "west" => -123.1,
                    "north" => 48.6,
                    "east" => -121.5
                  }
                }
              ],
              "agencies" => []
            })

  describe "read_manifest/1" do
    test "returns the manifest of the directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "manifest.json"), @manifest)

      assert {:ok, %{snapshot: "20261004", archives: [%{name: "basemap-20261004-01.pmtiles"}]}} =
               Basemap.read_manifest(tmp_dir)
    end

    test "returns :not_found for a directory without a manifest", %{tmp_dir: tmp_dir} do
      assert Basemap.read_manifest(tmp_dir) == {:error, :not_found}
    end

    test "returns :not_found for a directory that does not exist", %{tmp_dir: tmp_dir} do
      assert Basemap.read_manifest(Path.join(tmp_dir, "absent")) == {:error, :not_found}
    end

    test "returns the rule a manifest breaks", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "manifest.json"), "not json")

      assert Basemap.read_manifest(tmp_dir) == {:error, :invalid_json}
    end

    test "returns :too_large for a manifest past the bound and does not read it", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "manifest.json"), String.duplicate(" ", 1_048_577))

      assert Basemap.read_manifest(tmp_dir) == {:error, :too_large}
    end
  end
end
