defmodule Gobusgo.VendorAssetsTest do
  # Drives fetch/2 and update/2 against a Req.Test stub that serves a small
  # registry: tarballs built here and the metadata that names them. The lock
  # file and the vendor directory are in the test's temporary directory, so
  # every outcome is observed in the files written and the lock read back.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.VendorTarball
  alias Gobusgo.VendorAssets
  alias Gobusgo.VendorAssets.Lock
  alias Gobusgo.VendorAssets.Tarball

  @moduletag :tmp_dir

  @stub_name __MODULE__
  @options [plug: {Req.Test, @stub_name}, retry_delay_ms_base: 1]
  @name "pmtiles"
  @path "dist/pmtiles.js"

  defp tarball_url(version), do: "https://registry.npmjs.org/#{@name}/-/#{@name}-#{version}.tgz"

  # A registry with the given versions of one package, each a map of path to
  # content, and `latest` naming the last one. Reports each tarball request.
  defp stub_registry(versions, tmp_dir, overrides \\ %{}) do
    recipient = self()

    tarballs =
      Map.new(versions, fn {version, files} -> {version, VendorTarball.build(files, tmp_dir)} end)

    {latest, _files} = List.last(versions)

    metadata = fn version ->
      JSON.encode!(%{
        "name" => @name,
        "version" => version,
        "dist" => %{
          "tarball" => tarball_url(version),
          "integrity" =>
            Map.get(overrides, :integrity, Tarball.integrity(Map.fetch!(tarballs, version)))
        }
      })
    end

    Req.Test.stub(@stub_name, fn %{request_path: path} = conn ->
      case String.split(path, "/", trim: true) do
        [@name, "latest"] ->
          Plug.Conn.send_resp(conn, 200, metadata.(latest))

        [@name, "-", file] ->
          version =
            file |> String.replace_prefix("#{@name}-", "") |> String.replace_suffix(".tgz", "")

          send(recipient, {:tarball_requested, version})
          Plug.Conn.send_resp(conn, 200, Map.fetch!(tarballs, version))

        [@name, version] when is_map_key(tarballs, version) ->
          Plug.Conn.send_resp(conn, 200, metadata.(version))

        _other ->
          Plug.Conn.send_resp(conn, 404, ~s("not found"))
      end
    end)

    tarballs
  end

  defp paths(tmp_dir) do
    %{
      lock_path: Path.join(tmp_dir, "vendor.lock.json"),
      vendor_dir: Path.join(tmp_dir, "vendor"),
      static_dir: Path.join(tmp_dir, "static")
    }
  end

  defp update(tmp_dir, request) do
    request = Map.merge(%{name: @name, version: :latest, files: nil}, request)

    tmp_dir
    |> paths()
    |> Map.delete(:static_dir)
    |> Map.merge(request)
    |> VendorAssets.update(@options)
  end

  defp fetch(tmp_dir), do: VendorAssets.fetch(paths(tmp_dir), @options)

  defp read_lock(tmp_dir) do
    {:ok, lock} = tmp_dir |> paths() |> Map.fetch!(:lock_path) |> File.read!() |> Lock.decode()
    lock
  end

  defp vendored(tmp_dir, path \\ @path), do: Path.join([paths(tmp_dir).vendor_dir, @name, path])

  describe "update/2" do
    test "adds a package at its latest version with the named files", %{tmp_dir: tmp_dir} do
      tarballs =
        stub_registry([{"4.4.0", %{@path => "old"}}, {"4.5.0", %{@path => "new"}}], tmp_dir)

      assert update(tmp_dir, %{files: [@path]}) ==
               {:ok, %{name: @name, version: "4.5.0", previous_version: nil}}

      assert File.read!(vendored(tmp_dir)) == "new"

      assert read_lock(tmp_dir) == %{
               archives: [],
               packages: [
                 %{
                   name: @name,
                   version: "4.5.0",
                   tarball: tarball_url("4.5.0"),
                   integrity: Tarball.integrity(tarballs["4.5.0"]),
                   files: [%{path: @path, sha256: Tarball.sha256("new")}]
                 }
               ]
             }
    end

    test "moves a package to its latest version, keeping its files", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.4.0", %{@path => "old"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path]})
      stub_registry([{"4.4.0", %{@path => "old"}}, {"4.5.0", %{@path => "new"}}], tmp_dir)

      assert update(tmp_dir, %{}) ==
               {:ok, %{name: @name, version: "4.5.0", previous_version: "4.4.0"}}

      assert File.read!(vendored(tmp_dir)) == "new"
      assert [%{version: "4.5.0", files: [%{path: @path}]}] = read_lock(tmp_dir).packages
    end

    test "moves a package back to an older version that is asked for", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.4.0", %{@path => "old"}}, {"4.5.0", %{@path => "new"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path]})

      assert update(tmp_dir, %{version: "4.4.0"}) ==
               {:ok, %{name: @name, version: "4.4.0", previous_version: "4.5.0"}}

      assert File.read!(vendored(tmp_dir)) == "old"
      assert [%{version: "4.4.0", tarball: tarball}] = read_lock(tmp_dir).packages
      assert tarball == tarball_url("4.4.0")
    end

    test "removes a file the package no longer names", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new", "dist/extra.js" => "extra"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path, "dist/extra.js"]})

      assert {:ok, _updated} = update(tmp_dir, %{files: [@path]})
      assert File.exists?(vendored(tmp_dir, "dist/extra.js")) == false
      assert [%{files: [%{path: @path}]}] = read_lock(tmp_dir).packages
    end

    test "returns the package the lock does not hold when no file is named", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)

      assert update(tmp_dir, %{}) == {:error, {:unknown_package, @name}}
    end

    for {description, request, reason} <- [
          {"a malformed name", %{name: "../x"}, {:invalid_name, "../x"}},
          {"a malformed version", %{version: "newest"}, {:invalid_version, "newest"}},
          {"a path that climbs", %{files: ["../x.js"]}, {:invalid_file, "../x.js"}}
        ] do
      test "returns #{inspect(reason)} for #{description} and requests nothing", %{
        tmp_dir: tmp_dir
      } do
        Req.Test.stub(@stub_name, fn _conn -> flunk("no request expected") end)

        assert update(tmp_dir, unquote(Macro.escape(request))) ==
                 {:error, unquote(Macro.escape(reason))}
      end
    end

    test "returns the registry's failure for a version it does not have", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)

      assert update(tmp_dir, %{version: "9.9.9", files: [@path]}) ==
               {:error, {:registry, @name, :not_found}}
    end

    test "refuses a tarball that does not hash to the registry's integrity", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir, %{
        integrity: Tarball.integrity("other")
      })

      assert update(tmp_dir, %{files: [@path]}) == {:error, {:integrity_mismatch, @name}}
      assert File.exists?(vendored(tmp_dir)) == false
      assert File.exists?(paths(tmp_dir).lock_path) == false
    end

    test "leaves the lock as it was when the version lacks a file", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.4.0", %{@path => "old"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path]})
      lock = read_lock(tmp_dir)
      stub_registry([{"4.5.0", %{"dist/renamed.js" => "new"}}], tmp_dir)

      assert update(tmp_dir, %{}) == {:error, {:tarball, @name, {:file_missing, @path}}}
      assert read_lock(tmp_dir) == lock
      assert File.read!(vendored(tmp_dir)) == "old"
    end
  end

  describe "fetch/2" do
    setup %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path]})
      assert_received {:tarball_requested, "4.5.0"}
      :ok
    end

    test "downloads nothing for a package whose files are present", %{tmp_dir: tmp_dir} do
      assert fetch(tmp_dir) == {:ok, [%{name: @name, version: "4.5.0", status: :present}]}
      refute_received {:tarball_requested, _version}
    end

    test "downloads a package whose files are absent", %{tmp_dir: tmp_dir} do
      File.rm_rf!(paths(tmp_dir).vendor_dir)

      assert fetch(tmp_dir) == {:ok, [%{name: @name, version: "4.5.0", status: :downloaded}]}
      assert File.read!(vendored(tmp_dir)) == "new"
    end

    test "downloads a package whose file was changed", %{tmp_dir: tmp_dir} do
      File.write!(vendored(tmp_dir), "edited")

      assert fetch(tmp_dir) == {:ok, [%{name: @name, version: "4.5.0", status: :downloaded}]}
      assert File.read!(vendored(tmp_dir)) == "new"
    end

    test "refuses a tarball that does not hash to the lock's integrity", %{tmp_dir: tmp_dir} do
      File.rm_rf!(paths(tmp_dir).vendor_dir)
      stub_registry([{"4.5.0", %{@path => "tampered"}}], tmp_dir)

      assert fetch(tmp_dir) == {:error, {:integrity_mismatch, @name}}
      assert File.exists?(vendored(tmp_dir)) == false
    end

    test "returns the registry's failure", %{tmp_dir: tmp_dir} do
      File.rm_rf!(paths(tmp_dir).vendor_dir)
      Req.Test.stub(@stub_name, &Plug.Conn.send_resp(&1, 404, ""))

      assert fetch(tmp_dir) == {:error, {:registry, @name, :not_found}}
    end

    test "returns the rule a lock file breaks", %{tmp_dir: tmp_dir} do
      File.write!(paths(tmp_dir).lock_path, "not json")

      assert fetch(tmp_dir) == {:error, {:lock, :invalid_json}}
    end

    test "fetches nothing for a project without a lock file", %{tmp_dir: tmp_dir} do
      File.rm!(paths(tmp_dir).lock_path)

      assert fetch(tmp_dir) == {:ok, []}
    end
  end

  describe "entry_names/1" do
    test "returns the names in the lock by kind", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)
      {:ok, _added} = update(tmp_dir, %{files: [@path]})

      assert VendorAssets.entry_names(paths(tmp_dir).lock_path) ==
               {:ok, %{packages: [@name], archives: []}}
    end
  end

  describe "update_archive/2 and fetch/2 for an archive" do
    @archive "basemaps-assets"
    @repository "protomaps/basemaps-assets"
    @old_commit String.duplicate("a", 40)
    @new_commit String.duplicate("b", 40)

    # GitHub's archive host with the given commits of one repository, each a
    # map of path to content. Reports each request.
    defp stub_archives(commits, tmp_dir) do
      recipient = self()

      archives =
        Map.new(commits, fn {commit, files} ->
          {commit, VendorTarball.build_repository(files, tmp_dir)}
        end)

      Req.Test.stub(@stub_name, fn %{request_path: "/" <> path} = conn ->
        send(recipient, {:archive_requested, path})

        case String.split(path, "/tar.gz/") do
          [@repository, commit] when is_map_key(archives, commit) ->
            Plug.Conn.send_resp(conn, 200, Map.fetch!(archives, commit))

          _other ->
            Plug.Conn.send_resp(conn, 404, "404: Not Found")
        end
      end)
    end

    defp update_archive(tmp_dir, request) do
      request =
        Map.merge(
          %{name: @archive, commit: @new_commit, repository: nil, directories: nil},
          request
        )

      tmp_dir
      |> paths()
      |> Map.delete(:vendor_dir)
      |> Map.merge(request)
      |> VendorAssets.update_archive(@options)
    end

    defp served(tmp_dir, path), do: Path.join([paths(tmp_dir).static_dir, @archive, path])

    defp add_archive(tmp_dir) do
      stub_archives(
        [
          {@old_commit,
           %{"fonts/a.pbf" => "old", "fonts/gone.pbf" => "gone", "README.md" => "r"}},
          {@new_commit, %{"fonts/a.pbf" => "new", "sprites/v4/light.json" => "{}"}}
        ],
        tmp_dir
      )

      update_archive(tmp_dir, %{
        commit: @old_commit,
        repository: @repository,
        directories: ["fonts"]
      })
    end

    test "adds an archive at the commit with the named directories", %{tmp_dir: tmp_dir} do
      assert add_archive(tmp_dir) ==
               {:ok, %{name: @archive, version: @old_commit, previous_version: nil}}

      assert File.read!(served(tmp_dir, "fonts/a.pbf")) == "old"
      assert File.exists?(served(tmp_dir, "README.md")) == false

      assert read_lock(tmp_dir).archives == [
               %{
                 name: @archive,
                 repository: @repository,
                 commit: @old_commit,
                 directories: ["fonts"],
                 content_sha256:
                   Tarball.content_sha256(%{"fonts/a.pbf" => "old", "fonts/gone.pbf" => "gone"}),
                 file_count: 2
               }
             ]
    end

    test "moves an archive to another commit, keeping its repository and directories",
         %{tmp_dir: tmp_dir} do
      {:ok, _added} = add_archive(tmp_dir)

      assert update_archive(tmp_dir, %{}) ==
               {:ok, %{name: @archive, version: @new_commit, previous_version: @old_commit}}

      assert File.read!(served(tmp_dir, "fonts/a.pbf")) == "new"
      assert File.exists?(served(tmp_dir, "fonts/gone.pbf")) == false

      assert [%{commit: @new_commit, directories: ["fonts"], file_count: 1}] =
               read_lock(tmp_dir).archives
    end

    test "moves an archive back to an older commit", %{tmp_dir: tmp_dir} do
      {:ok, _added} = add_archive(tmp_dir)
      {:ok, _moved} = update_archive(tmp_dir, %{})

      assert update_archive(tmp_dir, %{commit: @old_commit}) ==
               {:ok, %{name: @archive, version: @old_commit, previous_version: @new_commit}}

      assert File.read!(served(tmp_dir, "fonts/a.pbf")) == "old"
    end

    test "keeps the packages of the lock", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)
      {:ok, _package} = update(tmp_dir, %{files: [@path]})
      {:ok, _added} = add_archive(tmp_dir)

      assert VendorAssets.entry_names(paths(tmp_dir).lock_path) ==
               {:ok, %{packages: [@name], archives: [@archive]}}
    end

    for {description, request, reason} <- [
          {"an archive the lock does not hold, with no repository", %{},
           {:unknown_package, "basemaps-assets"}},
          {"a commit that is not 40 hexadecimal digits",
           %{commit: "main", repository: "protomaps/basemaps-assets", directories: ["fonts"]},
           {:invalid_commit, "main"}},
          {"a malformed repository", %{repository: "protomaps", directories: ["fonts"]},
           {:invalid_repository, "protomaps"}},
          {"a directory that climbs",
           %{repository: "protomaps/basemaps-assets", directories: ["../x"]},
           {:invalid_directory, "../x"}},
          {"a malformed name",
           %{name: "a/b", repository: "protomaps/basemaps-assets", directories: ["fonts"]},
           {:invalid_name, "a/b"}}
        ] do
      test "returns #{inspect(reason)} for #{description} and requests nothing", %{
        tmp_dir: tmp_dir
      } do
        Req.Test.stub(@stub_name, fn _conn -> flunk("no request expected") end)

        assert update_archive(tmp_dir, unquote(Macro.escape(request))) ==
                 {:error, unquote(Macro.escape(reason))}
      end
    end

    test "returns the name a package already has", %{tmp_dir: tmp_dir} do
      stub_registry([{"4.5.0", %{@path => "new"}}], tmp_dir)
      {:ok, _package} = update(tmp_dir, %{files: [@path]})

      assert update_archive(tmp_dir, %{
               name: @name,
               repository: @repository,
               directories: ["fonts"]
             }) ==
               {:error, {:name_taken, @name}}
    end

    test "returns the name an archive already has when a package is asked for", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _added} = add_archive(tmp_dir)

      assert update(tmp_dir, %{name: @archive, files: [@path]}) ==
               {:error, {:name_taken, @archive}}
    end

    test "returns GitHub's failure for a commit it does not have", %{tmp_dir: tmp_dir} do
      {:ok, _added} = add_archive(tmp_dir)
      lock = read_lock(tmp_dir)

      assert update_archive(tmp_dir, %{commit: String.duplicate("c", 40)}) ==
               {:error, {:github, @archive, :not_found}}

      assert read_lock(tmp_dir) == lock
    end

    test "leaves the lock as it was when the commit lacks a directory", %{tmp_dir: tmp_dir} do
      {:ok, _added} = add_archive(tmp_dir)

      assert update_archive(tmp_dir, %{directories: ["icons"]}) ==
               {:error, {:tarball, @archive, {:directory_missing, "icons"}}}

      assert [%{commit: @old_commit}] = read_lock(tmp_dir).archives
    end

    test "fetch downloads nothing for an archive whose files are present", %{tmp_dir: tmp_dir} do
      {:ok, _added} = add_archive(tmp_dir)
      assert_received {:archive_requested, _path}

      assert fetch(tmp_dir) == {:ok, [%{name: @archive, version: @old_commit, status: :present}]}
      refute_received {:archive_requested, _path}
    end

    defp damage(:absent, tmp_dir), do: File.rm_rf!(paths(tmp_dir).static_dir)
    defp damage(:changed, tmp_dir), do: File.write!(served(tmp_dir, "fonts/a.pbf"), "edited")
    defp damage(:added, tmp_dir), do: File.write!(served(tmp_dir, "fonts/extra.pbf"), "extra")
    defp damage(:removed, tmp_dir), do: File.rm!(served(tmp_dir, "fonts/gone.pbf"))

    for {description, damage} <- [
          {"are absent", :absent},
          {"hold a changed file", :changed},
          {"hold an added file", :added},
          {"lack a file", :removed}
        ] do
      test "fetch downloads an archive whose files #{description}", %{tmp_dir: tmp_dir} do
        {:ok, _added} = add_archive(tmp_dir)
        damage(unquote(damage), tmp_dir)

        assert fetch(tmp_dir) ==
                 {:ok, [%{name: @archive, version: @old_commit, status: :downloaded}]}

        assert File.read!(served(tmp_dir, "fonts/a.pbf")) == "old"
        assert File.read!(served(tmp_dir, "fonts/gone.pbf")) == "gone"
        assert File.exists?(served(tmp_dir, "fonts/extra.pbf")) == false
      end
    end

    test "fetch refuses content that does not hash to the lock's content hash", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _added} = add_archive(tmp_dir)
      File.rm_rf!(paths(tmp_dir).static_dir)

      stub_archives(
        [{@old_commit, %{"fonts/a.pbf" => "tampered", "fonts/gone.pbf" => "gone"}}],
        tmp_dir
      )

      assert fetch(tmp_dir) == {:error, {:content_mismatch, @archive}}
      assert File.exists?(served(tmp_dir, "fonts/a.pbf")) == false
    end
  end
end
