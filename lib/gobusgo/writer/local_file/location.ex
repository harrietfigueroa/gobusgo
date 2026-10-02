defmodule Gobusgo.Writer.LocalFile.Location do
  @moduledoc """
  Places validated destination segments under the base directory of the local
  file backend. Pure: nothing here touches the file system, so the symlink
  walk stays in `Gobusgo.Writer.LocalFile`, which owns the IO.
  """

  alias Gobusgo.Assert

  @doc """
  Joins `segments` under the absolute `base_dir`. The result sits strictly
  below `base_dir`; a segment list that `Path.safe_relative/2` resolves out of
  it, which happens when a symlink redirects it, returns `:redirected`.
  """
  @spec place([String.t(), ...], Path.t()) ::
          {:ok, Path.t()} | {:error, {:invalid_destination, :redirected}}
  def place(segments, base_dir) when is_list(segments) and is_binary(base_dir) do
    Assert.condition(Path.type(base_dir) == :absolute, "base_dir must be absolute: #{base_dir}")

    # Path.safe_relative/2 backs up the segment allowlist: the two checks are
    # independent paths to the same no-escape property.
    case segments |> Path.join() |> Path.safe_relative(base_dir) do
      {:ok, safe} ->
        path = Path.join(base_dir, safe)
        Assert.condition(String.starts_with?(path, base_dir <> "/"), "path escaped base: #{path}")
        {:ok, path}

      :error ->
        {:error, {:invalid_destination, :redirected}}
    end
  end
end
