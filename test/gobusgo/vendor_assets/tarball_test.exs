defmodule Gobusgo.VendorAssets.TarballTest do
  # Verifies the tarball functions over tarballs built here in the registry's
  # form: the hashes of known bytes, and the files taken out of an archive.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.VendorTarball
  alias Gobusgo.VendorAssets.Tarball

  @moduletag :tmp_dir

  describe "integrity/1 and sha256/1" do
    test "hash the empty content to the published values" do
      assert Tarball.integrity("") ==
               "sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg=="

      assert Tarball.sha256("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end
  end

  describe "extract/2" do
    test "returns the content of each named file", %{tmp_dir: tmp_dir} do
      tarball =
        VendorTarball.build(
          %{"dist/a.js" => "a", "dist/b.js" => "b", "README.md" => "r"},
          tmp_dir
        )

      assert Tarball.extract(tarball, ["dist/a.js", "dist/b.js"]) ==
               {:ok, %{"dist/a.js" => "a", "dist/b.js" => "b"}}
    end

    test "returns the path the tarball does not hold", %{tmp_dir: tmp_dir} do
      tarball = VendorTarball.build(%{"dist/a.js" => "a"}, tmp_dir)

      assert Tarball.extract(tarball, ["dist/a.js", "dist/c.js"]) ==
               {:error, {:file_missing, "dist/c.js"}}
    end

    test "returns :tarball_invalid for bytes that are not an archive" do
      assert Tarball.extract("not a tarball", ["dist/a.js"]) == {:error, :tarball_invalid}
    end
  end

  describe "content_sha256/1" do
    test "is the same for the same files in any order" do
      assert Tarball.content_sha256(%{"a" => "1", "b" => "2"}) ==
               Tarball.content_sha256(Map.new([{"b", "2"}, {"a", "1"}]))
    end

    for {description, other} <- [
          {"another content", %{"a" => "1", "b" => "3"}},
          {"another path", %{"a" => "1", "c" => "2"}},
          {"a content moved to another path", %{"a" => "2", "b" => "1"}},
          {"one file fewer", %{"a" => "1"}}
        ] do
      test "differs for #{description}" do
        assert Tarball.content_sha256(%{"a" => "1", "b" => "2"}) !=
                 Tarball.content_sha256(unquote(Macro.escape(other)))
      end
    end
  end

  describe "extract_directories/2" do
    test "returns the files under the named directories, by path inside the repository",
         %{tmp_dir: tmp_dir} do
      archive =
        VendorTarball.build_repository(
          %{
            "fonts/Noto Sans Regular/0-255.pbf" => "glyphs",
            "sprites/v4/light.json" => "{}",
            "sprites/v3/light.json" => "old",
            "README.md" => "readme"
          },
          tmp_dir
        )

      assert Tarball.extract_directories(archive, ["fonts", "sprites/v4"]) ==
               {:ok,
                %{
                  "fonts/Noto Sans Regular/0-255.pbf" => "glyphs",
                  "sprites/v4/light.json" => "{}"
                }}
    end

    test "leaves out a directory whose name only starts like a named one", %{tmp_dir: tmp_dir} do
      archive =
        VendorTarball.build_repository(%{"fonts/a.pbf" => "a", "fonts-old/b.pbf" => "b"}, tmp_dir)

      assert Tarball.extract_directories(archive, ["fonts"]) == {:ok, %{"fonts/a.pbf" => "a"}}
    end

    test "returns the directory the archive does not hold", %{tmp_dir: tmp_dir} do
      archive = VendorTarball.build_repository(%{"fonts/a.pbf" => "a"}, tmp_dir)

      assert Tarball.extract_directories(archive, ["fonts", "sprites/v4"]) ==
               {:error, {:directory_missing, "sprites/v4"}}
    end

    test "returns :tarball_invalid for bytes that are not an archive" do
      assert Tarball.extract_directories("not a tarball", ["fonts"]) == {:error, :tarball_invalid}
    end
  end
end
