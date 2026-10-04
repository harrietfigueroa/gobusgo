defmodule Gobusgo.VendorAssets.LockTest do
  # Verifies the lock file as pure functions over literal text and packages:
  # the text a lock is written as, the lock a text is read as, and each rule
  # a lock has to obey.
  use ExUnit.Case, async: true

  alias Gobusgo.VendorAssets.Lock

  @integrity "sha512-" <> Base.encode64(String.duplicate(<<1>>, 64))
  @sha256 String.duplicate("a", 64)
  @package %{
    name: "pmtiles",
    version: "4.5.0",
    tarball: "https://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz",
    integrity: @integrity,
    files: [%{path: "dist/pmtiles.js", sha256: @sha256}]
  }
  @scoped %{
    name: "@protomaps/basemaps",
    version: "5.7.2",
    tarball: "https://registry.npmjs.org/@protomaps/basemaps/-/basemaps-5.7.2.tgz",
    integrity: @integrity,
    files: [%{path: "dist/esm/index.js", sha256: @sha256}]
  }

  @archive %{
    name: "basemaps-assets",
    repository: "protomaps/basemaps-assets",
    commit: String.duplicate("a", 40),
    directories: ["fonts", "sprites/v4"],
    content_sha256: @sha256,
    file_count: 3
  }

  defp text(packages, archives \\ []), do: Lock.encode(%{packages: packages, archives: archives})

  describe "encode/1 and decode/1" do
    test "read back the lock that was written" do
      lock = %{packages: [@scoped, @package], archives: [@archive]}

      assert lock |> Lock.encode() |> Lock.decode() == {:ok, lock}
    end

    test "write one value per line, packages in name order" do
      assert text([@package], [@archive]) == """
             {
               "packages": [
                 {
                   "name": "pmtiles",
                   "version": "4.5.0",
                   "tarball": "https://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz",
                   "integrity": "#{@integrity}",
                   "files": [
                     {"path": "dist/pmtiles.js", "sha256": "#{@sha256}"}
                   ]
                 }
               ],
               "archives": [
                 {
                   "name": "basemaps-assets",
                   "repository": "protomaps/basemaps-assets",
                   "commit": "#{String.duplicate("a", 40)}",
                   "directories": ["fonts", "sprites/v4"],
                   "contentSha256": "#{@sha256}",
                   "fileCount": 3
                 }
               ]
             }
             """

      assert {:ok, %{packages: [%{name: "@protomaps/basemaps"}, %{name: "pmtiles"}]}} =
               [@package, @scoped] |> text() |> Lock.decode()
    end

    test "write and read a lock with no package" do
      assert Lock.encode(Lock.empty()) == ~s({\n  "packages": [],\n  "archives": []\n}\n)
      assert Lock.decode(Lock.encode(Lock.empty())) == {:ok, Lock.empty()}
    end
  end

  describe "decode/1" do
    test "returns :invalid_json for text that is not JSON" do
      assert Lock.decode("not json") == {:error, :invalid_json}
    end

    test "returns the mismatch for JSON that is not a lock" do
      assert {:error, {:schema_mismatch, %{path: ["packages"]}}} =
               Lock.decode(~s({"packages": 1, "archives": []}))
    end

    test "returns the name a lock holds twice" do
      assert Lock.decode(text([@package, @package])) == {:error, {:duplicate_name, "pmtiles"}}
    end

    test "returns the name a package and an archive share" do
      assert Lock.decode(text([@package], [%{@archive | name: "pmtiles"}])) ==
               {:error, {:duplicate_name, "pmtiles"}}
    end

    test "returns the count of more archives than the bound" do
      archives = for index <- 1..9, do: %{@archive | name: "archive-#{index}"}

      assert Lock.decode(text([], archives)) == {:error, {:archive_count_exceeded, 9}}
    end

    for {description, change, field} <- [
          {"a name with a directory", %{name: "a/b"}, :name},
          {"a name that climbs", %{name: ".."}, :name},
          {"a repository without an owner", %{repository: "basemaps-assets"}, :repository},
          {"a repository that climbs", %{repository: "protomaps/.."}, :repository},
          {"a short commit", %{commit: "028c18f"}, :commit},
          {"a commit that is a branch", %{commit: "main"}, :commit},
          {"no directory", %{directories: []}, :directories},
          {"a directory that climbs", %{directories: ["../fonts"]}, :directories},
          {"a directory named twice", %{directories: ["fonts", "fonts"]}, :directories},
          {"a short content hash", %{content_sha256: "abc"}, :content_sha256},
          {"no file", %{file_count: 0}, :file_count}
        ] do
      test "returns #{field} as invalid for an archive with #{description}" do
        archive = Map.merge(@archive, unquote(Macro.escape(change)))

        assert Lock.decode(text([], [archive])) ==
                 {:error, {:invalid_archive, archive.name, unquote(field)}}
      end
    end

    test "returns the count of more packages than the bound" do
      packages = for index <- 1..33, do: %{@package | name: "package-#{index}"}

      assert Lock.decode(text(packages)) == {:error, {:package_count_exceeded, 33}}
    end

    for {description, change, field} <- [
          {"a name with an uppercase letter", %{name: "PMTiles"}, :name},
          {"a name with a path", %{name: "../pmtiles"}, :name},
          {"a version that is a tag", %{version: "latest"}, :version},
          {"a version with a path", %{version: "4.5.0/../x"}, :version},
          {"a tarball on another host", %{tarball: "https://example.test/pmtiles-4.5.0.tgz"},
           :tarball},
          {"a tarball over HTTP",
           %{tarball: "http://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz"}, :tarball},
          {"a tarball with user information",
           %{tarball: "https://user@registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz"}, :tarball},
          {"an integrity of another algorithm", %{integrity: "sha1-" <> Base.encode64("x")},
           :integrity},
          {"an integrity of the wrong length", %{integrity: "sha512-" <> Base.encode64("short")},
           :integrity},
          {"no file", %{files: []}, :files},
          {"a file named twice",
           %{
             files: [
               %{path: "dist/pmtiles.js", sha256: String.duplicate("a", 64)},
               %{path: "dist/pmtiles.js", sha256: String.duplicate("a", 64)}
             ]
           }, :files},
          {"a path that climbs",
           %{files: [%{path: "../x.js", sha256: String.duplicate("a", 64)}]}, :path},
          {"an absolute path",
           %{files: [%{path: "/etc/x.js", sha256: String.duplicate("a", 64)}]}, :path},
          {"a hidden file", %{files: [%{path: "dist/.x.js", sha256: String.duplicate("a", 64)}]},
           :path},
          {"a hash in uppercase", %{files: [%{path: "x.js", sha256: String.duplicate("A", 64)}]},
           :sha256},
          {"a short hash", %{files: [%{path: "x.js", sha256: "abc"}]}, :sha256}
        ] do
      test "returns #{field} as invalid for #{description}" do
        package = Map.merge(@package, unquote(Macro.escape(change)))

        assert Lock.decode(text([package])) ==
                 {:error, {:invalid_package, package.name, unquote(field)}}
      end
    end
  end

  describe "put_package/2 and fetch_package/2" do
    test "add a package the lock does not hold" do
      lock = Lock.put_package(%{packages: [@package], archives: []}, @scoped)

      assert Enum.map(lock.packages, & &1.name) == ["@protomaps/basemaps", "pmtiles"]
      assert Lock.fetch_package(lock, "@protomaps/basemaps") == {:ok, @scoped}
    end

    test "replace the package of the same name" do
      lock =
        Lock.put_package(%{packages: [@package], archives: []}, %{@package | version: "4.6.0"})

      assert [%{version: "4.6.0"}] = lock.packages
    end

    test "return :error for a package the lock does not hold" do
      assert Lock.fetch_package(%{packages: [@package], archives: []}, "maplibre-gl") == :error
    end
  end

  describe "put_archive/2 and fetch_archive/2" do
    test "add an archive and keep the packages" do
      lock = Lock.put_archive(%{packages: [@package], archives: []}, @archive)

      assert lock.packages == [@package]
      assert Lock.fetch_archive(lock, "basemaps-assets") == {:ok, @archive}
    end

    test "replace the archive of the same name" do
      commit = String.duplicate("b", 40)
      lock = Lock.put_archive(%{packages: [], archives: [@archive]}, %{@archive | commit: commit})

      assert [%{commit: ^commit}] = lock.archives
    end

    test "return :error for an archive the lock does not hold" do
      assert Lock.fetch_archive(Lock.empty(), "basemaps-assets") == :error
    end
  end
end
