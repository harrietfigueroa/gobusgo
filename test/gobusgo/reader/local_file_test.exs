defmodule Gobusgo.Reader.LocalFileTest do
  # Verifies the local file backend against a real temporary directory: one
  # behavior per test, covering reads, discovery order and paging, missing
  # and unreadable files, and rejected destinations including traversal and
  # symlinks. Files are created with File directly, so only the reader is
  # under test.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader
  alias Gobusgo.Reader.LocalFile

  @moduletag :tmp_dir

  defp read(tmp_dir, destination) do
    Reader.read(destination, backend: LocalFile, base_dir: tmp_dir)
  end

  defp discover(tmp_dir, prefix, overrides \\ []) do
    {options, request} = Keyword.split(overrides, [:entries_max])

    %{prefix: prefix, limit: 100, order: :ascending, cursor: nil}
    |> Map.merge(Map.new(request))
    |> Reader.discover([backend: LocalFile, base_dir: tmp_dir] ++ options)
  end

  defp put(tmp_dir, destination, content \\ "x") do
    path = Path.join(tmp_dir, destination)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp root?, do: match?({"0\n", 0}, System.cmd("id", ["-u"]))

  describe "successful reads" do
    test "returns the content at the destination", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "a.json", "{}")

      assert read(tmp_dir, "a.json") == {:ok, "{}"}
    end

    test "reads a destination below nested directories", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/dt=2026-10-02/a.json", "nested")

      assert read(tmp_dir, "raw/dt=2026-10-02/a.json") == {:ok, "nested"}
    end

    test "returns bytes that are not valid UTF-8 unchanged", %{tmp_dir: tmp_dir} do
      content = <<0, 255, 254, 10, 13>>
      put(tmp_dir, "bin", content)

      assert read(tmp_dir, "bin") == {:ok, content}
    end

    test "returns empty content", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "empty", "")

      assert read(tmp_dir, "empty") == {:ok, ""}
    end

    test "returns content at the size limit", %{tmp_dir: tmp_dir} do
      content = :binary.copy(<<0>>, LocalFile.content_bytes_max())
      put(tmp_dir, "big", content)

      assert read(tmp_dir, "big") == {:ok, content}
    end

    test "reads the base directory from application config when not injected", %{
      tmp_dir: tmp_dir
    } do
      previous = Application.fetch_env!(:gobusgo, LocalFile)
      on_exit(fn -> Application.put_env(:gobusgo, LocalFile, previous) end)
      Application.put_env(:gobusgo, LocalFile, base_dir: tmp_dir)
      put(tmp_dir, "cfg.json", "configured")

      assert Reader.read("cfg.json", backend: LocalFile) == {:ok, "configured"}
    end
  end

  describe "missing content" do
    test "returns not_found for a destination that does not exist", %{tmp_dir: tmp_dir} do
      assert read(tmp_dir, "absent.json") == {:error, :not_found}
    end

    test "returns not_found below a directory that does not exist", %{tmp_dir: tmp_dir} do
      assert read(tmp_dir, "raw/absent.json") == {:error, :not_found}
    end

    test "returns not_found when the base directory does not exist", %{tmp_dir: tmp_dir} do
      assert read(Path.join(tmp_dir, "never-created"), "a.json") == {:error, :not_found}
    end

    test "returns not_found when the destination is a directory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "raw"))

      assert read(tmp_dir, "raw") == {:error, :not_found}
    end

    test "returns not_found when a parent segment is a file", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "a")

      assert read(tmp_dir, "a/b.json") == {:error, :not_found}
    end
  end

  describe "read failures" do
    test "returns permission_denied when the file is not readable", %{tmp_dir: tmp_dir} do
      if root?() do
        # Root ignores file permissions, so the failure cannot be provoked.
        :ok
      else
        path = put(tmp_dir, "locked.json")
        File.chmod!(path, 0o000)
        on_exit(fn -> File.chmod!(path, 0o600) end)

        assert read(tmp_dir, "locked.json") == {:error, :permission_denied}
      end
    end

    test "returns permission_denied when a parent directory is not searchable", %{
      tmp_dir: tmp_dir
    } do
      if root?() do
        # Root ignores directory permissions, so the failure cannot be provoked.
        :ok
      else
        put(tmp_dir, "locked/a.json")
        locked = Path.join(tmp_dir, "locked")
        File.chmod!(locked, 0o000)
        on_exit(fn -> File.chmod!(locked, 0o700) end)

        assert read(tmp_dir, "locked/a.json") == {:error, :permission_denied}
      end
    end

    test "returns content_too_large above the size limit", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "big", :binary.copy(<<0>>, LocalFile.content_bytes_max() + 1))

      assert read(tmp_dir, "big") == {:error, :content_too_large}
    end
  end

  describe "rejected destinations on read" do
    for {name, destination} <- [
          {"parent traversal", "../escape.json"},
          {"embedded traversal", "a/../../escape.json"},
          {"an absolute path", "/etc/hosts"},
          {"an empty destination", ""},
          {"a hidden name", ".tmp-1"}
        ] do
      test "rejects #{name}", %{tmp_dir: tmp_dir} do
        assert {:error, {:invalid_destination, _reason}} = read(tmp_dir, unquote(destination))
      end
    end

    test "reads nothing outside the base directory through traversal", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "secret.json", "secret")
      base = Path.join(tmp_dir, "base")
      File.mkdir_p!(base)

      assert read(base, "../secret.json") == {:error, {:invalid_destination, :traversal}}
    end

    test "rejects a symlinked directory segment", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "outside/a.json", "secret")
      base = Path.join(tmp_dir, "base")
      File.mkdir_p!(base)
      File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(base, "link"))

      assert read(base, "link/a.json") == {:error, {:invalid_destination, :redirected}}
    end

    test "rejects a destination that is itself a symlink", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "target", "secret")
      File.ln_s!(Path.join(tmp_dir, "target"), Path.join(tmp_dir, "link"))

      assert read(tmp_dir, "link") == {:error, {:invalid_destination, :redirected}}
    end

    test "rejects a symlink whose target does not exist", %{tmp_dir: tmp_dir} do
      File.ln_s!(Path.join(tmp_dir, "absent"), Path.join(tmp_dir, "link"))

      assert read(tmp_dir, "link") == {:error, {:invalid_destination, :redirected}}
    end
  end

  describe "discovery" do
    test "lists the destinations in a partition", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/dt=2026-10-02/b.json")
      put(tmp_dir, "raw/dt=2026-10-02/a.json")

      assert discover(tmp_dir, "raw/dt=2026-10-02/") ==
               {:ok,
                %{
                  destinations: ["raw/dt=2026-10-02/a.json", "raw/dt=2026-10-02/b.json"],
                  cursor: nil
                }}
    end

    test "lists destinations across nested partitions in order", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/dt=2026-10-03/a.json")
      put(tmp_dir, "raw/dt=2026-10-02/b.json")
      put(tmp_dir, "raw/dt=2026-10-02/a.json")

      assert {:ok, %{destinations: destinations}} = discover(tmp_dir, "raw/")

      assert destinations == [
               "raw/dt=2026-10-02/a.json",
               "raw/dt=2026-10-02/b.json",
               "raw/dt=2026-10-03/a.json"
             ]
    end

    test "matches a partial name", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "out/20261002_a.json")
      put(tmp_dir, "out/20261002_b.json")
      put(tmp_dir, "out/20261003_a.json")

      assert {:ok, %{destinations: destinations}} = discover(tmp_dir, "out/20261002_")
      assert destinations == ["out/20261002_a.json", "out/20261002_b.json"]
    end

    test "matches a partial name of a nested level", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/dt=2026-10-02/a.json")
      put(tmp_dir, "raw/dt=2026-11-01/a.json")

      assert {:ok, %{destinations: destinations}} = discover(tmp_dir, "raw/dt=2026-10")
      assert destinations == ["raw/dt=2026-10-02/a.json"]
    end

    test "orders destinations by bytes across files and directories", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "p/a/x")
      put(tmp_dir, "p/a-b")
      put(tmp_dir, "p/a0")

      assert {:ok, %{destinations: destinations}} = discover(tmp_dir, "p/")
      assert destinations == ["p/a-b", "p/a/x", "p/a0"]
      assert destinations == Enum.sort(destinations)
    end

    test "lists in descending order", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "p/a/x")
      put(tmp_dir, "p/a-b")
      put(tmp_dir, "p/a0")

      assert {:ok, %{destinations: destinations}} = discover(tmp_dir, "p/", order: :descending)
      assert destinations == ["p/a0", "p/a/x", "p/a-b"]
    end

    test "returns the greatest destination with a descending limit of one", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "out/20261002_a.json")
      put(tmp_dir, "out/20261003_a.json")

      assert discover(tmp_dir, "out/", order: :descending, limit: 1) ==
               {:ok, %{destinations: ["out/20261003_a.json"], cursor: "out/20261003_a.json"}}
    end

    test "returns an empty page when nothing matches", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/a.json")

      assert discover(tmp_dir, "raw/b") == {:ok, %{destinations: [], cursor: nil}}
    end

    test "returns an empty page when the prefix levels do not exist", %{tmp_dir: tmp_dir} do
      assert discover(tmp_dir, "raw/dt=2026-10-02/") == {:ok, %{destinations: [], cursor: nil}}
    end

    test "returns an empty page when the base directory does not exist", %{tmp_dir: tmp_dir} do
      assert discover(Path.join(tmp_dir, "never-created"), "raw/") ==
               {:ok, %{destinations: [], cursor: nil}}
    end

    test "returns an empty page when a prefix level is a file", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw")

      assert discover(tmp_dir, "raw/") == {:ok, %{destinations: [], cursor: nil}}
    end

    test "leaves out hidden names and names outside the allowlist", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/a.json")
      put(tmp_dir, "raw/.tmp-1F")
      put(tmp_dir, "raw/.trash/b.json")
      put(tmp_dir, "raw/with space")

      assert {:ok, %{destinations: ["raw/a.json"]}} = discover(tmp_dir, "raw/")
    end

    test "leaves out symlinks without following them", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "outside/secret.json")
      put(tmp_dir, "base/raw/a.json")
      base = Path.join(tmp_dir, "base")
      File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(base, "raw/linked"))
      File.ln_s!(Path.join(tmp_dir, "outside/secret.json"), Path.join(base, "raw/link.json"))

      assert {:ok, %{destinations: ["raw/a.json"]}} = discover(base, "raw/")
    end

    test "leaves out destinations deeper than the destination rules allow", %{tmp_dir: tmp_dir} do
      levels = List.duplicate("d", Gobusgo.Destination.segment_count_max())
      put(tmp_dir, Path.join(["p" | levels]))
      put(tmp_dir, "p/a")

      assert {:ok, %{destinations: ["p/a"]}} = discover(tmp_dir, "p/")
    end

    test "every discovered destination is readable", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "raw/dt=2026-10-02/a.json", "first")
      put(tmp_dir, "raw/dt=2026-10-03/a.json", "second")

      {:ok, %{destinations: destinations}} = discover(tmp_dir, "raw/")

      assert Enum.map(destinations, &read(tmp_dir, &1)) == [{:ok, "first"}, {:ok, "second"}]
    end
  end

  describe "discovery paging" do
    setup %{tmp_dir: tmp_dir} do
      for name <- ["d1/a", "d1/b", "d2/a", "d2/b", "e"], do: put(tmp_dir, "p/" <> name)
      :ok
    end

    test "returns at most the limit and a cursor when more exist", %{tmp_dir: tmp_dir} do
      assert discover(tmp_dir, "p/", limit: 2) ==
               {:ok, %{destinations: ["p/d1/a", "p/d1/b"], cursor: "p/d1/b"}}
    end

    test "continues after the cursor", %{tmp_dir: tmp_dir} do
      assert discover(tmp_dir, "p/", limit: 2, cursor: "p/d1/b") ==
               {:ok, %{destinations: ["p/d2/a", "p/d2/b"], cursor: "p/d2/b"}}
    end

    test "returns no cursor on the last page", %{tmp_dir: tmp_dir} do
      assert discover(tmp_dir, "p/", limit: 2, cursor: "p/d2/b") ==
               {:ok, %{destinations: ["p/e"], cursor: nil}}
    end

    test "returns no cursor when the page ends exactly at the last destination", %{
      tmp_dir: tmp_dir
    } do
      assert discover(tmp_dir, "p/", limit: 5) ==
               {:ok,
                %{destinations: ["p/d1/a", "p/d1/b", "p/d2/a", "p/d2/b", "p/e"], cursor: nil}}
    end

    test "pages through every destination exactly once in either order", %{tmp_dir: tmp_dir} do
      for order <- [:ascending, :descending] do
        pages =
          Stream.unfold(:first, fn
            :done ->
              nil

            cursor ->
              cursor =
                case cursor do
                  :first -> nil
                  cursor -> cursor
                end

              {:ok, page} = discover(tmp_dir, "p/", limit: 2, order: order, cursor: cursor)
              {page.destinations, page.cursor || :done}
          end)

        all = ["p/d1/a", "p/d1/b", "p/d2/a", "p/d2/b", "p/e"]
        expected = if order == :ascending, do: all, else: Enum.reverse(all)

        assert pages |> Enum.take(4) |> Enum.concat() == expected
      end
    end

    test "continues after a cursor whose destination no longer exists", %{tmp_dir: tmp_dir} do
      assert {:ok, %{destinations: ["p/d2/a", "p/d2/b", "p/e"]}} =
               discover(tmp_dir, "p/", cursor: "p/d1/zz")
    end
  end

  describe "discovery failures" do
    test "returns invalid_cursor for a cursor that is not a destination", %{tmp_dir: tmp_dir} do
      assert discover(tmp_dir, "p/", cursor: "../x") == {:error, :invalid_cursor}
    end

    for {name, prefix, reason} <- [
          {"an empty prefix", "", :empty},
          {"a traversing prefix", "../", :traversal},
          {"an absolute prefix", "/etc/", :absolute},
          {"a hidden prefix", "raw/.trash/", :segment_invalid}
        ] do
      test "rejects #{name}", %{tmp_dir: tmp_dir} do
        assert discover(tmp_dir, unquote(prefix)) ==
                 {:error, {:invalid_destination, unquote(reason)}}
      end
    end

    test "rejects a symlinked prefix level and lists nothing behind it", %{tmp_dir: tmp_dir} do
      put(tmp_dir, "outside/secret.json")
      base = Path.join(tmp_dir, "base")
      File.mkdir_p!(base)
      File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(base, "link"))

      assert discover(base, "link/") == {:error, {:invalid_destination, :redirected}}
    end

    test "returns permission_denied when a directory is not listable", %{tmp_dir: tmp_dir} do
      if root?() do
        # Root ignores directory permissions, so the failure cannot be provoked.
        :ok
      else
        put(tmp_dir, "raw/locked/a.json")
        locked = Path.join(tmp_dir, "raw/locked")
        File.chmod!(locked, 0o000)
        on_exit(fn -> File.chmod!(locked, 0o700) end)

        assert discover(tmp_dir, "raw/") == {:error, :permission_denied}
      end
    end

    test "returns discovery_too_large when the entries exceed the bound", %{tmp_dir: tmp_dir} do
      for name <- ["a", "b", "c"], do: put(tmp_dir, "raw/" <> name)

      assert discover(tmp_dir, "raw/", entries_max: 2) == {:error, :discovery_too_large}
    end

    test "lists when the entries equal the bound", %{tmp_dir: tmp_dir} do
      for name <- ["a", "b", "c"], do: put(tmp_dir, "raw/" <> name)

      assert {:ok, %{destinations: ["raw/a", "raw/b", "raw/c"]}} =
               discover(tmp_dir, "raw/", entries_max: 3)
    end
  end

  describe "configuration" do
    test "raises when the base directory is relative" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Reader.read("a", backend: LocalFile, base_dir: "relative")
      end
    end

    test "raises when no base directory is configured" do
      previous = Application.fetch_env!(:gobusgo, LocalFile)
      on_exit(fn -> Application.put_env(:gobusgo, LocalFile, previous) end)
      Application.put_env(:gobusgo, LocalFile, [])

      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Reader.discover(%{prefix: "a/", limit: 1, order: :ascending, cursor: nil},
          backend: LocalFile
        )
      end
    end

    test "raises when the entries bound is not a positive integer", %{tmp_dir: tmp_dir} do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        discover(tmp_dir, "raw/", entries_max: 0)
      end
    end
  end
end
