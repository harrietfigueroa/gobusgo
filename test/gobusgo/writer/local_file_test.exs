defmodule Gobusgo.Writer.LocalFileTest do
  # Verifies the local file backend against a real temporary directory: one
  # behavior per test, covering success, each failure class, create-only
  # collisions, and rejected destinations including traversal and symlinks.
  use ExUnit.Case, async: true

  alias Gobusgo.Writer
  alias Gobusgo.Writer.LocalFile

  @moduletag :tmp_dir

  # Path.safe_relative/2 resolves symlinks and can report :traversal before
  # the backend's own lstat walk reports :symlink; both reject the write.
  @symlink_reasons [:symlink, :traversal]

  defp write(tmp_dir, destination, content) do
    Writer.write(%{destination: destination, content: content},
      backend: LocalFile,
      base_dir: tmp_dir
    )
  end

  describe "successful writes" do
    test "writes the content to the destination under the base directory", %{tmp_dir: tmp_dir} do
      assert write(tmp_dir, "a.json", "{}") == :ok
      assert File.read!(Path.join(tmp_dir, "a.json")) == "{}"
    end

    test "creates missing parent directories", %{tmp_dir: tmp_dir} do
      assert write(tmp_dir, "raw/dt=2026-10-02/a.json", "x") == :ok
      assert File.read!(Path.join(tmp_dir, "raw/dt=2026-10-02/a.json")) == "x"
    end

    test "writes into an existing parent directory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "raw"))

      assert write(tmp_dir, "raw/a.json", "x") == :ok
    end

    test "round-trips bytes that are not valid UTF-8", %{tmp_dir: tmp_dir} do
      content = <<0, 255, 254, 10, 13>>

      assert write(tmp_dir, "bin", content) == :ok
      assert File.read!(Path.join(tmp_dir, "bin")) == content
    end

    test "writes empty content", %{tmp_dir: tmp_dir} do
      assert write(tmp_dir, "empty", "") == :ok
      assert File.read!(Path.join(tmp_dir, "empty")) == ""
    end

    test "leaves no temporary file behind", %{tmp_dir: tmp_dir} do
      assert write(tmp_dir, "a.json", "x") == :ok
      assert File.ls!(tmp_dir) == ["a.json"]
    end

    test "reads the base directory from application config when not injected", %{
      tmp_dir: tmp_dir
    } do
      previous = Application.fetch_env!(:gobusgo, LocalFile)
      on_exit(fn -> Application.put_env(:gobusgo, LocalFile, previous) end)
      Application.put_env(:gobusgo, LocalFile, base_dir: tmp_dir)

      assert Writer.write(%{destination: "cfg.json", content: "x"}, backend: LocalFile) == :ok
      assert File.exists?(Path.join(tmp_dir, "cfg.json"))
    end
  end

  describe "create-only collisions" do
    test "returns already_exists when the destination exists", %{tmp_dir: tmp_dir} do
      assert write(tmp_dir, "a.json", "first") == :ok
      assert write(tmp_dir, "a.json", "second") == {:error, :already_exists}
    end

    test "keeps the original content after a collision", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "a.json", "first")
      write(tmp_dir, "a.json", "second")

      assert File.read!(Path.join(tmp_dir, "a.json")) == "first"
    end

    test "leaves no temporary file behind after a collision", %{tmp_dir: tmp_dir} do
      write(tmp_dir, "a.json", "first")
      write(tmp_dir, "a.json", "second")

      assert File.ls!(tmp_dir) == ["a.json"]
    end

    test "returns already_exists when the destination is a directory", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "d"))

      assert write(tmp_dir, "d", "x") == {:error, :already_exists}
    end
  end

  describe "filesystem failures" do
    test "returns destination_conflict when a parent segment is a file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a"), "file")

      assert write(tmp_dir, "a/b.json", "x") == {:error, :destination_conflict}
    end

    test "returns permission_denied when the directory is not writable", %{tmp_dir: tmp_dir} do
      if match?({"0\n", 0}, System.cmd("id", ["-u"])) do
        # Root ignores directory permissions, so the failure cannot be provoked.
        :ok
      else
        locked = Path.join(tmp_dir, "locked")
        File.mkdir_p!(locked)
        File.chmod!(locked, 0o500)
        on_exit(fn -> File.chmod!(locked, 0o700) end)

        assert write(tmp_dir, "locked/a.json", "x") == {:error, :permission_denied}
      end
    end

    test "returns content_too_large above the size limit", %{tmp_dir: tmp_dir} do
      content = :binary.copy(<<0>>, LocalFile.content_bytes_max() + 1)

      assert write(tmp_dir, "big", content) == {:error, :content_too_large}
      assert File.ls!(tmp_dir) == []
    end

    test "accepts content at the size limit", %{tmp_dir: tmp_dir} do
      content = :binary.copy(<<0>>, LocalFile.content_bytes_max())

      assert write(tmp_dir, "big", content) == :ok
    end
  end

  describe "rejected destinations" do
    for {name, destination} <- [
          {"parent traversal", "../escape.json"},
          {"embedded traversal", "a/../../escape.json"},
          {"an absolute path", "/tmp/escape.json"},
          {"an empty destination", ""}
        ] do
      test "rejects #{name} and writes nothing", %{tmp_dir: tmp_dir} do
        assert {:error, {:invalid_destination, _reason}} =
                 write(tmp_dir, unquote(destination), "x")

        assert File.ls!(tmp_dir) == []
      end
    end

    test "rejects a symlinked directory segment and writes nothing outside", %{tmp_dir: tmp_dir} do
      outside = Path.join(tmp_dir, "outside")
      base = Path.join(tmp_dir, "base")
      File.mkdir_p!(outside)
      File.mkdir_p!(base)
      File.ln_s!(outside, Path.join(base, "link"))

      assert {:error, {:invalid_destination, reason}} = write(base, "link/a.json", "x")
      assert reason in @symlink_reasons
      assert File.ls!(outside) == []
    end

    test "rejects a destination that is itself a symlink", %{tmp_dir: tmp_dir} do
      File.ln_s!(Path.join(tmp_dir, "target"), Path.join(tmp_dir, "link"))

      assert {:error, {:invalid_destination, reason}} = write(tmp_dir, "link", "x")
      assert reason in @symlink_reasons
    end
  end

  describe "configuration" do
    test "raises when the base directory is relative", %{tmp_dir: _tmp_dir} do
      assert_raise Gobusgo.AssertionError, fn ->
        Writer.write(%{destination: "a", content: "x"}, backend: LocalFile, base_dir: "relative")
      end
    end

    test "raises when no base directory is configured" do
      previous = Application.fetch_env!(:gobusgo, LocalFile)
      on_exit(fn -> Application.put_env(:gobusgo, LocalFile, previous) end)
      Application.put_env(:gobusgo, LocalFile, [])

      assert_raise Gobusgo.AssertionError, fn ->
        Writer.write(%{destination: "a", content: "x"}, backend: LocalFile)
      end
    end
  end
end
