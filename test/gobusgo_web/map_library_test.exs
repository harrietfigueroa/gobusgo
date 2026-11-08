defmodule GobusgoWeb.MapLibraryTest do
  # These tests check the address a page loads the map library from. The
  # functions of a version are called with versions written here, and the
  # version in use is compared with the one the lock file pins.
  use ExUnit.Case, async: true

  alias Gobusgo.VendorAssets.Lock
  alias GobusgoWeb.MapLibrary

  describe "directory/1" do
    test "names the package and the version" do
      assert MapLibrary.directory("6.12.0") == "maplibre-gl-6.12.0"
    end

    test "differs between two versions" do
      assert MapLibrary.directory("6.12.0") != MapLibrary.directory("6.12.1")
    end

    test "raises for a value that is no version" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> MapLibrary.directory("../6.12.0") end
    end
  end

  describe "url/1" do
    test "is the library's entry file inside the version's directory of the built assets" do
      assert MapLibrary.url("6.12.0") == "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl.mjs"
    end
  end

  describe "module_paths/1" do
    test "are the library's three module files inside the version's directory" do
      assert MapLibrary.module_paths("6.12.0") == [
               "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl.mjs",
               "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl-shared.mjs",
               "/assets/vendor/maplibre-gl-6.12.0/maplibre-gl-worker.mjs"
             ]
    end
  end

  describe "version/0" do
    test "is the version the lock file pins" do
      {:ok, lock} = Lock.decode(File.read!("assets/vendor.lock.json"))
      {:ok, package} = Lock.fetch_package(lock, "maplibre-gl")

      assert MapLibrary.version() == package.version
    end
  end
end
