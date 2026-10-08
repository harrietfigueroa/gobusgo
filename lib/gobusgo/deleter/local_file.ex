defmodule Gobusgo.Deleter.LocalFile do
  @moduledoc """
  `Gobusgo.Deleter` backend that removes destinations stored as files under
  a base directory. The standard library is the only dependency.

  ## Options

    * `:base_dir` — absolute directory the destinations live under. Defaults
      to the `:base_dir` of `config :gobusgo, Gobusgo.Deleter.LocalFile`.

  ## What is removed

  The file at the destination is unlinked, which a reader sees as the whole
  file or none. Then each directory between the file and the directory of
  `within` is removed while it is empty, the deepest first, stopping at the
  first one that still holds an entry. The directory of `within` stays.

  A destination that is a directory is `:destination_conflict`, and one whose
  file, or a directory on the way to it, does not exist is `:not_found`. A
  symlinked segment, or a destination that is itself a symlink, is rejected
  as `{:invalid_destination, :redirected}` and nothing is removed.

  A directory that cannot be removed for a reason other than holding an
  entry returns that reason while the file is gone.
  """

  @behaviour Gobusgo.Deleter

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.LocalFile.Location

  @impl Gobusgo.Deleter
  def delete(%{destination: destination, within: within}, options)
      when is_binary(destination) and is_binary(within) and is_list(options) do
    base_dir = fetch_base_dir(options)

    with {:ok, segments} <- Destination.validate(destination),
         {:ok, %{segments: within_segments, remainder: ""}} <- Destination.validate_prefix(within),
         {:ok, path} <- Location.place(segments, base_dir),
         :ok <- check_file(base_dir, segments),
         :ok <- remove_file(path) do
      # The directories the deletion may leave empty: every level of the
      # destination deeper than `within`, the file's own name left out.
      emptied_count = length(segments) - 1 - length(within_segments)
      Assert.condition(emptied_count >= 0, "the destination must lie below within")
      remove_empty_directories(Path.dirname(path), emptied_count)
    end
  end

  defp fetch_base_dir(options) do
    base_dir =
      Keyword.get_lazy(options, :base_dir, fn ->
        :gobusgo |> Application.get_env(__MODULE__, []) |> Keyword.get(:base_dir)
      end)

    Assert.condition(
      is_binary(base_dir),
      "base_dir must be configured, got: #{inspect(base_dir)}"
    )

    Assert.condition(Path.type(base_dir) == :absolute, "base_dir must be absolute: #{base_dir}")
    base_dir
  end

  # Stats each segment below the base without resolving links, so a symlink
  # anywhere on the way is seen as one, and says what the last segment is.
  defp check_file(base_dir, segments) do
    segments
    |> Enum.reduce_while({:ok, base_dir, nil}, fn segment, {:ok, parent, _type} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:invalid_destination, :redirected}}}

        {:ok, %File.Stat{type: type}} ->
          {:cont, {:ok, path, type}}

        {:error, posix} ->
          {:halt, {:error, to_reason(posix)}}
      end
    end)
    |> case do
      {:ok, _path, :regular} -> :ok
      {:ok, _path, _other_type} -> {:error, :destination_conflict}
      {:error, _reason} = error -> error
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, posix} -> {:error, to_reason(posix)}
    end
  end

  defp remove_empty_directories(_directory, 0), do: :ok

  defp remove_empty_directories(directory, count) when count > 0 do
    case File.rmdir(directory) do
      :ok -> remove_empty_directories(Path.dirname(directory), count - 1)
      # The directory holds an entry, or another deletion removed it first.
      {:error, posix} when posix in [:eexist, :enotempty, :enoent] -> :ok
      {:error, posix} -> {:error, to_reason(posix)}
    end
  end

  # The closed mapping from POSIX reasons to the deleter's error reasons. A
  # reason outside it raises, so a new failure mode surfaces as a programmer
  # error.
  defp to_reason(:enoent), do: :not_found
  defp to_reason(:enotdir), do: :not_found
  defp to_reason(:eacces), do: :permission_denied
  defp to_reason(:eperm), do: :permission_denied
  defp to_reason(:erofs), do: :read_only
  defp to_reason(:eio), do: :io_failure
  defp to_reason(:eisdir), do: :destination_conflict
  defp to_reason(:enametoolong), do: {:invalid_destination, :too_long}
  defp to_reason(:eloop), do: {:invalid_destination, :redirected}
  defp to_reason(other), do: Assert.unreachable(other)
end
