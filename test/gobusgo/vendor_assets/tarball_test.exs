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
end
