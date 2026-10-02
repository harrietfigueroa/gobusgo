defmodule Gobusgo.Writer.LocalFile do
  @moduledoc """
  `Gobusgo.Writer` backend that stores destinations as files under a base
  directory. The standard library is the only dependency.

  ## Options

    * `:base_dir` — absolute directory the destinations live under. Defaults
      to the `:base_dir` of `config :gobusgo, Gobusgo.Writer.LocalFile`. Expand
      it once in config (`Path.expand/1`), so a changing working directory
      cannot move it.

  ## Example

      config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.LocalFile
      config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: Path.expand("data")

      :ok =
        Gobusgo.Writer.write(%{
          destination: "raw/oba/dt=2026-10-02/response.json",
          content: ~s({"ok":true})
        })

      {:error, :already_exists} =
        Gobusgo.Writer.write(%{
          destination: "raw/oba/dt=2026-10-02/response.json",
          content: "second"
        })

  ## Durability sequence

  The content goes to an exclusive hidden temporary file in the destination
  directory, is synced, then published with a hard link, which fails with
  `:eexist` when the destination exists and so gives create-only behavior.
  The temporary name is removed and the directory is synced. A failure before
  publication leaves no file at the destination; a directory sync failure
  after publication returns an error while the destination exists.

  A symlinked segment, or a destination that is itself a symlink, is rejected
  as `{:invalid_destination, :redirected}`. POSIX reasons map to the writer's
  error reasons in `Gobusgo.Writer.LocalFile.PosixError`. Symlink rejection is a check followed by a later open, and the standard
  library has no `O_NOFOLLOW`, so a process that can write inside the base
  directory can race it. The base directory must be writable only by this
  application.
  """

  @behaviour Gobusgo.Writer

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.LocalFile.Location
  alias Gobusgo.Writer.LocalFile.PosixError

  @content_bytes_max 16 * 1024 * 1024
  @temp_prefix ".tmp-"
  @temp_random_bytes_max 0xFFFFFFFFFFFF

  @doc "Content bytes allowed in one write."
  @spec content_bytes_max() :: pos_integer()
  def content_bytes_max, do: @content_bytes_max

  @impl Gobusgo.Writer
  def write(%{destination: destination, content: content}, options)
      when is_binary(destination) and is_binary(content) and is_list(options) do
    base_dir = fetch_base_dir(options)

    with :ok <- check_content_size(content),
         {:ok, segments} <- Destination.validate(destination),
         {:ok, path} <- Location.place(segments, base_dir),
         :ok <- reject_symlinks(base_dir, segments),
         :ok <- make_parent(path) do
      publish(path, content)
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

  defp check_content_size(content) do
    if byte_size(content) <= @content_bytes_max do
      :ok
    else
      {:error, :content_too_large}
    end
  end

  # Walks the segments below the base, stopping at the first one that does
  # not exist yet; everything past it is created by this write.
  defp reject_symlinks(base_dir, segments) do
    segments
    |> Enum.reduce_while(base_dir, fn segment, parent ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:invalid_destination, :redirected}}}

        {:ok, %File.Stat{}} ->
          {:cont, path}

        {:error, posix} when posix in [:enoent, :enotdir] ->
          {:halt, :ok}

        {:error, posix} ->
          {:halt, {:error, PosixError.to_reason(posix)}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _ok_or_path -> :ok
    end
  end

  defp make_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      # A file occupies a parent level; mkdir_p reports it as :eexist.
      {:error, :eexist} -> {:error, :destination_conflict}
      {:error, posix} -> {:error, PosixError.to_reason(posix)}
    end
  end

  defp publish(path, content) do
    directory = Path.dirname(path)
    temp = Path.join(directory, temp_name())

    result =
      try do
        with :ok <- write_temp(temp, content),
             :ok <- link(temp, path) do
          :ok
        end
      catch
        kind, reason ->
          # Cleanup is best effort: the original failure is what propagates.
          _ = File.rm(temp)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    finish(result, temp, directory)
  end

  defp finish(:ok, temp, directory) do
    with :ok <- remove_temp(temp) do
      sync_directory(directory)
    end
  end

  defp finish({:error, _reason} = error, temp, _directory) do
    # The write failed; the original error is the outcome. A temp that cannot
    # be removed stays hidden under its reserved prefix.
    _ = File.rm(temp)
    error
  end

  defp temp_name do
    random = :rand.uniform(@temp_random_bytes_max)

    @temp_prefix <>
      Integer.to_string(random, 16) <>
      "-" <> Integer.to_string(System.unique_integer([:positive]), 16)
  end

  defp write_temp(temp, content) do
    case :file.open(temp, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        write_and_close(device, content)

      {:error, :eexist} ->
        raise Assert.AssertionError, message: "temporary name collided: #{temp}"

      {:error, posix} ->
        {:error, PosixError.to_reason(posix)}
    end
  end

  defp write_and_close(device, content) do
    result =
      with :ok <- :file.write(device, content) do
        :file.sync(device)
      end

    close_result = :file.close(device)

    case {result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, posix}, _close} -> {:error, PosixError.to_reason(posix)}
      {:ok, {:error, posix}} -> {:error, PosixError.to_reason(posix)}
    end
  end

  defp link(temp, path) do
    case :file.make_link(temp, path) do
      :ok -> :ok
      {:error, posix} -> {:error, PosixError.to_reason(posix)}
    end
  end

  defp remove_temp(temp) do
    case File.rm(temp) do
      :ok -> :ok
      {:error, posix} -> {:error, PosixError.to_reason(posix)}
    end
  end

  defp sync_directory(directory) do
    case :file.open(directory, [:read, :directory]) do
      {:ok, device} ->
        sync_result = :file.sync(device)
        close_result = :file.close(device)

        with :ok <- sync_result,
             :ok <- close_result do
          :ok
        else
          {:error, posix} -> {:error, PosixError.to_reason(posix)}
        end

      {:error, posix} ->
        {:error, PosixError.to_reason(posix)}
    end
  end
end
