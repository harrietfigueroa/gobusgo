defmodule GobusgoWeb.ServiceWorkerTest do
  # Checks the pure functions the service worker's build takes its release
  # from: the paths it stores when it installs, with and without a digest of
  # the built assets, the release identifier of a set of files, and the
  # object the worker is built with. Every input is written here.
  use ExUnit.Case, async: true

  alias Gobusgo.VendorAssets.Lock
  alias GobusgoWeb.MapLibrary
  alias GobusgoWeb.ServiceWorker

  @digests %{
    "assets/css/app.css" => "assets/css/app-0123456789abcdef0123456789abcdef.css",
    "assets/js/app.js" => "assets/js/app-fedcba9876543210fedcba9876543210.js"
  }

  describe "precache_paths/1" do
    test "names the digested stylesheet and script of a digested build" do
      paths = ServiceWorker.precache_paths({:digested, @digests})

      assert "/assets/css/app-0123456789abcdef0123456789abcdef.css" in paths
      assert "/assets/js/app-fedcba9876543210fedcba9876543210.js" in paths
    end

    test "names the stylesheet and script as built when the build has no digest" do
      paths = ServiceWorker.precache_paths(:undigested)

      assert "/assets/css/app.css" in paths
      assert "/assets/js/app.js" in paths
    end

    test "names the map library's module files at the addresses a page loads them from" do
      paths = ServiceWorker.precache_paths({:digested, @digests})

      assert MapLibrary.module_paths(MapLibrary.version()) -- paths == []
    end

    test "raises for a digest that leaves out the script" do
      digests = Map.delete(@digests, "assets/js/app.js")

      assert_raise Gobusgo.Assert.AssertionError, fn ->
        ServiceWorker.precache_paths({:digested, digests})
      end
    end
  end

  describe "release/1" do
    @files [{"/assets/js/app.js", "one"}, {"/assets/css/app.css", "two"}]

    test "is 16 lowercase hexadecimal digits" do
      assert ServiceWorker.release(@files) =~ ~r/\A[0-9a-f]{16}\z/
    end

    test "is the same for the same files" do
      assert ServiceWorker.release(@files) == ServiceWorker.release(@files)
    end

    test "changes when a file's content changes" do
      changed = [{"/assets/js/app.js", "one!"}, {"/assets/css/app.css", "two"}]

      assert ServiceWorker.release(changed) != ServiceWorker.release(@files)
    end

    test "changes when content moves from one file to another" do
      moved = [{"/assets/js/app.js", "onetwo"}, {"/assets/css/app.css", ""}]
      split = [{"/assets/js/app.js", "one"}, {"/assets/css/app.css", "two"}]

      assert ServiceWorker.release(moved) != ServiceWorker.release(split)
    end
  end

  describe "build/1" do
    test "holds the release, the paths, and the basemap assets' content identifier" do
      build = ServiceWorker.build(%{release: "0123456789abcdef", precache_paths: ["/a.js"]})

      assert build == %{
               "release" => "0123456789abcdef",
               "precachePaths" => ["/a.js"],
               "basemapAssetsId" => ServiceWorker.basemap_assets_id()
             }
    end
  end

  describe "basemap_assets_id/0" do
    test "is the start of the content hash the lock file pins for the basemap's fonts and sprites" do
      {:ok, lock} = Lock.decode(File.read!("assets/vendor.lock.json"))
      {:ok, archive} = Lock.fetch_archive(lock, "basemaps-assets")

      assert String.starts_with?(archive.content_sha256, ServiceWorker.basemap_assets_id())
      assert String.length(ServiceWorker.basemap_assets_id()) == 16
    end
  end
end
