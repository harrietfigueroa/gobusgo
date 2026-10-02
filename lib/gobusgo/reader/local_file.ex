defmodule Gobusgo.Reader.LocalFile do
  @content_bytes_max 16 * 1024 * 1024
  @entries_max 100_000

  @moduledoc """
  `Gobusgo.Reader` backend that loads destinations from files under a base
  directory. The standard library is the only dependency.

  ## Options

    * `:base_dir` — absolute directory the destinations live under. Defaults
      to the `:base_dir` of `config :gobusgo, Gobusgo.Reader.LocalFile`. Expand
      it once in config (`Path.expand/1`), so a changing working directory
      cannot move it.
    * `:entries_max` — directory entries one `discover/2` call may examine.
      Defaults to #{@entries_max}.

  ## Example

      config :gobusgo, Gobusgo.Reader, backend: Gobusgo.Reader.LocalFile
      config :gobusgo, Gobusgo.Reader.LocalFile, base_dir: Path.expand("data")

      {:ok, content} = Gobusgo.Reader.read("raw/oba/dt=2026-10-02/response.json")

      {:ok, %{destinations: destinations, cursor: nil}} =
        Gobusgo.Reader.discover(%{
          prefix: "raw/oba/dt=2026-10-02/",
          limit: 100,
          order: :ascending,
          cursor: nil
        })

  ## Reading

  A destination is a regular file below the base directory. A missing file, a
  missing directory, a missing base directory, a directory at the destination
  and a file where a directory is expected are all `:not_found`. A file larger
  than #{@content_bytes_max} bytes is `:content_too_large`. POSIX reasons map
  to the reader's error reasons in `Gobusgo.Reader.LocalFile.PosixError`.

  ## Discovery

  Discovery walks the directories the prefix reaches, lazily and in order, and
  stops once the page is full. Regular files whose whole destination passes
  `Gobusgo.Destination.validate/1` are listed. Hidden names, names outside the
  allowlist, symlinks, and files that are neither regular nor directories are
  left out, and symlinks are never followed. A prefix whose directories do not
  exist yields an empty page.

  The cursor is the last destination of the page. Directories that sort
  entirely before it are skipped without being listed.

  The standard library lists a directory whole, so one directory's names are
  held in memory at once. A call that examines more than `:entries_max`
  directory entries returns `:discovery_too_large`.

  ## Symlinks

  A symlinked segment, or a destination that is itself a symlink, is rejected
  as `{:invalid_destination, :redirected}`, for reads and for the complete
  segments of a discovery prefix. Symlink rejection is a check followed by a
  later open, and the standard library has no `O_NOFOLLOW`, so a process that
  can write inside the base directory can race it. The base directory must be
  writable only by this application.
  """

  @behaviour Gobusgo.Reader

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.LocalFile.Location
  alias Gobusgo.Reader.LocalFile.Listing
  alias Gobusgo.Reader.LocalFile.PosixError

  @doc "Content bytes allowed in one read."
  @spec content_bytes_max() :: pos_integer()
  def content_bytes_max, do: @content_bytes_max

  @impl Gobusgo.Reader
  def read(destination, options) when is_binary(destination) and is_list(options) do
    base_dir = fetch_base_dir(options)

    with {:ok, segments} <- Destination.validate(destination),
         {:ok, path} <- Location.place(segments, base_dir),
         {:ok, stat} <- find(base_dir, segments),
         :ok <- check_file(stat) do
      read_file(path)
    else
      :absent -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @impl Gobusgo.Reader
  def discover(%{prefix: prefix, limit: limit, order: order, cursor: cursor}, options)
      when is_binary(prefix) and is_integer(limit) and is_list(options) do
    Assert.condition(limit >= 1, "limit must be at least 1, got: #{limit}")

    context = %{
      base_dir: fetch_base_dir(options),
      bounds: %{order: order, cursor: cursor}
    }

    entries_max = fetch_entries_max(options)

    with {:ok, %{segments: segments, remainder: remainder}} <- Destination.validate_prefix(prefix),
         :ok <- check_cursor(cursor),
         :ok <- check_start(context.base_dir, segments),
         parent = Enum.map_join(segments, &(&1 <> "/")),
         start = %{parent: parent, remainder: remainder, budget: entries_max},
         {:ok, entries, budget} <- list_directory(context, start),
         # One destination past the limit tells whether a further page exists.
         state = %{stack: [entries], found: [], wanted: limit + 1, budget: budget},
         {:ok, found} <- walk(state, context) do
      {:ok, page(found, limit)}
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

  defp fetch_entries_max(options) do
    entries_max = Keyword.get(options, :entries_max, @entries_max)

    Assert.condition(
      is_integer(entries_max),
      "entries_max must be an integer, got: #{inspect(entries_max)}"
    )

    Assert.condition(entries_max >= 1, "entries_max must be at least 1, got: #{entries_max}")
    entries_max
  end

  # Stats each segment below the base without resolving links, so a symlink
  # at any level is seen as one.
  defp find(base_dir, segments) do
    segments
    |> Enum.reduce_while({base_dir, nil}, fn segment, {parent, _stat} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:invalid_destination, :redirected}}}

        {:ok, %File.Stat{} = stat} ->
          {:cont, {path, stat}}

        {:error, posix} when posix in [:enoent, :enotdir] ->
          {:halt, :absent}

        {:error, posix} ->
          {:halt, {:error, PosixError.to_reason(posix)}}
      end
    end)
    |> case do
      {_path, %File.Stat{} = stat} -> {:ok, stat}
      absent_or_error -> absent_or_error
    end
  end

  defp check_file(%File.Stat{type: :regular, size: size}) do
    if size <= @content_bytes_max do
      :ok
    else
      {:error, :content_too_large}
    end
  end

  defp check_file(%File.Stat{}), do: {:error, :not_found}

  defp read_file(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        # One byte past the limit shows a file that grew after the size check.
        read_result = :file.read(device, @content_bytes_max + 1)
        close_result = :file.close(device)
        content(%{read: read_result, close: close_result})

      {:error, posix} ->
        {:error, PosixError.to_reason(posix)}
    end
  end

  defp content(%{read: {:error, posix}}), do: {:error, PosixError.to_reason(posix)}
  defp content(%{close: {:error, posix}}), do: {:error, PosixError.to_reason(posix)}
  defp content(%{read: :eof, close: :ok}), do: {:ok, ""}

  defp content(%{read: {:ok, data}, close: :ok}) do
    if byte_size(data) <= @content_bytes_max do
      {:ok, data}
    else
      {:error, :content_too_large}
    end
  end

  defp check_cursor(nil), do: :ok

  defp check_cursor(cursor) when is_binary(cursor) do
    case Destination.validate(cursor) do
      {:ok, _segments} -> :ok
      {:error, {:invalid_destination, _reason}} -> {:error, :invalid_cursor}
    end
  end

  defp check_start(_base_dir, []), do: :ok

  defp check_start(base_dir, segments) do
    with {:ok, _path} <- Location.place(segments, base_dir) do
      case find(base_dir, segments) do
        {:ok, %File.Stat{}} -> :ok
        # A start directory that does not exist lists as empty.
        :absent -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  # Depth-first over a stack of arranged directory listings. Every step
  # consumes an entry or a frame, and the entries are bounded by the budget.
  defp walk(%{stack: stack} = state, context) do
    frame_count = length(stack)

    Assert.condition(
      frame_count <= Destination.segment_count_max() + 1,
      "walk is #{frame_count} directories deep"
    )

    case stack do
      [] ->
        {:ok, Enum.reverse(state.found)}

      [[] | frames] ->
        walk(%{state | stack: frames}, context)

      [[%{kind: :file} = entry | siblings] | frames] ->
        state = %{
          state
          | stack: [siblings | frames],
            found: [entry.destination | state.found],
            wanted: state.wanted - 1
        }

        if state.wanted == 0 do
          {:ok, Enum.reverse(state.found)}
        else
          walk(state, context)
        end

      [[%{kind: :directory} = entry | siblings] | frames] ->
        below = %{parent: entry.destination <> "/", remainder: "", budget: state.budget}

        with {:ok, entries, budget} <- list_directory(context, below) do
          walk(%{state | stack: [entries, siblings | frames], budget: budget}, context)
        end
    end
  end

  # `parent` is the destination prefix of the directory: "" for the base
  # directory, otherwise its segments each followed by "/".
  defp list_directory(context, %{parent: parent, remainder: remainder, budget: budget}) do
    case File.ls(Path.join(context.base_dir, parent)) do
      {:ok, names} ->
        budget = budget - length(names)

        if budget >= 0 do
          destinations =
            for name <- names, String.starts_with?(name, remainder), do: parent <> name

          with {:ok, entries} <- classify(context, destinations) do
            {:ok, Listing.arrange(entries, context.bounds), budget}
          end
        else
          {:error, :discovery_too_large}
        end

      # The directory is absent, or was removed after its parent was listed.
      {:error, posix} when posix in [:enoent, :enotdir] ->
        {:ok, [], budget}

      {:error, posix} ->
        {:error, PosixError.to_reason(posix)}
    end
  end

  defp classify(context, destinations) do
    Enum.reduce_while(destinations, {:ok, []}, fn destination, {:ok, entries} ->
      case kind(context, destination) do
        {:ok, kind} -> {:cont, {:ok, [%{destination: destination, kind: kind} | entries]}}
        :skip -> {:cont, {:ok, entries}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp kind(context, destination) do
    case Destination.validate(destination) do
      {:ok, _segments} -> lstat_kind(Path.join(context.base_dir, destination))
      {:error, {:invalid_destination, _reason}} -> :skip
    end
  end

  defp lstat_kind(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, :file}
      {:ok, %File.Stat{type: :directory}} -> {:ok, :directory}
      {:ok, %File.Stat{}} -> :skip
      # The entry was removed after its directory was listed.
      {:error, :enoent} -> :skip
      {:error, posix} -> {:error, PosixError.to_reason(posix)}
    end
  end

  defp page(found, limit) do
    {destinations, beyond} = Enum.split(found, limit)

    cursor =
      case beyond do
        [] -> nil
        [_next] -> List.last(destinations)
      end

    %{destinations: destinations, cursor: cursor}
  end
end
