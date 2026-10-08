defmodule Gobusgo.Deleter.LocalFileTest do
  # Verifies the local file backend against real files under the test's
  # temporary directory: what a deletion removes, what it leaves, and the
  # outcome of each destination it cannot delete.
  use ExUnit.Case, async: true

  alias Gobusgo.Deleter
  alias Gobusgo.Deleter.LocalFile
  alias Gobusgo.Reader
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @within "raw/oba/"
  @destination "raw/oba/dt=2026-10-02/agency=1/a.json"

  defp write(base_dir, destination) do
    :ok =
      Writer.write(%{destination: destination, content: "content"},
        backend: Writer.LocalFile,
        base_dir: base_dir
      )
  end

  defp delete(base_dir, destination, within \\ @within) do
    Deleter.delete(%{destination: destination, within: within},
      backend: LocalFile,
      base_dir: base_dir
    )
  end

  defp exists?(base_dir, relative), do: File.exists?(Path.join(base_dir, relative))

  describe "delete/2" do
    test "removes the content, so a read finds nothing", %{tmp_dir: base_dir} do
      write(base_dir, @destination)

      assert delete(base_dir, @destination) == :ok

      assert Reader.read(@destination, backend: Reader.LocalFile, base_dir: base_dir) ==
               {:error, :not_found}
    end

    test "removes the content, so discovery leaves it out", %{tmp_dir: base_dir} do
      write(base_dir, @destination)
      write(base_dir, "raw/oba/dt=2026-10-02/agency=1/b.json")

      assert delete(base_dir, @destination) == :ok

      assert {:ok, %{destinations: ["raw/oba/dt=2026-10-02/agency=1/b.json"]}} =
               Reader.discover(%{prefix: @within, limit: 10, order: :ascending, cursor: nil},
                 backend: Reader.LocalFile,
                 base_dir: base_dir
               )
    end

    test "removes every directory below within that it leaves empty", %{tmp_dir: base_dir} do
      write(base_dir, @destination)

      assert delete(base_dir, @destination) == :ok

      refute exists?(base_dir, "raw/oba/dt=2026-10-02/agency=1")
      refute exists?(base_dir, "raw/oba/dt=2026-10-02")
    end

    test "leaves the directory of within, even when it is empty", %{tmp_dir: base_dir} do
      write(base_dir, @destination)

      assert delete(base_dir, @destination) == :ok

      assert exists?(base_dir, "raw/oba")
      assert File.ls!(Path.join(base_dir, "raw/oba")) == []
    end

    test "leaves a directory that still holds content, and everything above it", %{
      tmp_dir: base_dir
    } do
      write(base_dir, @destination)
      write(base_dir, "raw/oba/dt=2026-10-02/agency=40/b.json")

      assert delete(base_dir, @destination) == :ok

      refute exists?(base_dir, "raw/oba/dt=2026-10-02/agency=1")
      assert exists?(base_dir, "raw/oba/dt=2026-10-02/agency=40/b.json")
    end

    test "leaves the directory of a file directly below within", %{tmp_dir: base_dir} do
      write(base_dir, "usage/dt=2026-10-02/a.json")

      assert delete(base_dir, "usage/dt=2026-10-02/a.json", "usage/dt=2026-10-02/") == :ok

      assert exists?(base_dir, "usage/dt=2026-10-02")
    end

    test "answers not found for content deleted already", %{tmp_dir: base_dir} do
      write(base_dir, @destination)
      write(base_dir, "raw/oba/dt=2026-10-02/agency=1/b.json")
      :ok = delete(base_dir, @destination)

      assert delete(base_dir, @destination) == {:error, :not_found}
    end

    test "answers not found below a directory that does not exist", %{tmp_dir: base_dir} do
      assert delete(base_dir, @destination) == {:error, :not_found}
    end

    test "answers not found below a level that is a file", %{tmp_dir: base_dir} do
      write(base_dir, "raw/oba/dt=2026-10-02")

      assert delete(base_dir, @destination) == {:error, :not_found}
      assert exists?(base_dir, "raw/oba/dt=2026-10-02")
    end

    test "refuses a destination that is a directory, and removes nothing", %{tmp_dir: base_dir} do
      write(base_dir, @destination)

      assert delete(base_dir, "raw/oba/dt=2026-10-02/agency=1") ==
               {:error, :destination_conflict}

      assert exists?(base_dir, @destination)
    end

    test "refuses a destination that is a symlink, and removes nothing", %{tmp_dir: base_dir} do
      write(base_dir, "raw/oba/dt=2026-10-02/agency=1/real.json")
      link = Path.join(base_dir, @destination)
      :ok = File.ln_s(Path.join(base_dir, "raw/oba/dt=2026-10-02/agency=1/real.json"), link)

      assert delete(base_dir, @destination) == {:error, {:invalid_destination, :redirected}}
      assert {:ok, _stat} = File.lstat(link)
      assert exists?(base_dir, "raw/oba/dt=2026-10-02/agency=1/real.json")
    end

    test "refuses a destination below a symlinked directory, and removes nothing", %{
      tmp_dir: base_dir
    } do
      outside = Path.join(base_dir, "outside")
      File.mkdir_p!(Path.join(outside, "agency=1"))
      File.write!(Path.join(outside, "agency=1/a.json"), "content")
      File.mkdir_p!(Path.join(base_dir, "raw/oba"))
      :ok = File.ln_s(outside, Path.join(base_dir, "raw/oba/dt=2026-10-02"))

      assert delete(base_dir, @destination) == {:error, {:invalid_destination, :redirected}}
      assert File.exists?(Path.join(outside, "agency=1/a.json"))
    end

    for {destination, reason} <- [
          {"raw/oba/../../etc/passwd", :traversal},
          {"raw/oba/.hidden", :segment_invalid},
          {"raw/oba/a b.json", :segment_invalid}
        ] do
      test "refuses the destination #{destination} as #{reason}", %{tmp_dir: base_dir} do
        assert delete(base_dir, unquote(destination)) ==
                 {:error, {:invalid_destination, unquote(reason)}}
      end
    end

    test "answers permission denied for a directory it may not change", %{tmp_dir: base_dir} do
      write(base_dir, @destination)
      directory = Path.join(base_dir, "raw/oba/dt=2026-10-02/agency=1")
      File.chmod!(directory, 0o500)
      on_exit(fn -> File.chmod!(directory, 0o700) end)

      assert delete(base_dir, @destination) == {:error, :permission_denied}
      assert exists?(base_dir, @destination)
    end
  end
end
