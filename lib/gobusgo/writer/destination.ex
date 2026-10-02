defmodule Gobusgo.Writer.Destination do
  @moduledoc """
  Validation of logical destinations against a base directory. Everything
  here is pure: no function touches the filesystem, so symlink checks live
  in the backend that owns the IO.
  """

  alias Gobusgo.Assert

  @destination_bytes_max 1024
  @segment_bytes_max 128
  @segment_count_max 16

  # The first character excludes `.` so that `.`, `..`, and hidden files fail.
  @segment_pattern ~r/\A[A-Za-z0-9_=-][A-Za-z0-9._=-]*\z/

  @reasons [
    :empty,
    :too_long,
    :not_utf8,
    :nul_byte,
    :absolute,
    :too_deep,
    :segment_too_long,
    :segment_invalid,
    :traversal,
    :symlink
  ]

  @type reason ::
          :empty
          | :too_long
          | :not_utf8
          | :nul_byte
          | :absolute
          | :too_deep
          | :segment_too_long
          | :segment_invalid
          | :traversal
          | :symlink

  @type resolved :: %{segments: [String.t(), ...], path: Path.t()}

  @doc "Every reason a destination can be rejected for."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "Bytes allowed in one path segment."
  @spec segment_bytes_max() :: pos_integer()
  def segment_bytes_max, do: @segment_bytes_max

  @doc """
  Validates `destination` and joins it under the absolute `base_dir`.
  Returns the validated segments and the resulting path, which is guaranteed
  to sit strictly below `base_dir`.
  """
  @spec resolve(String.t(), Path.t()) ::
          {:ok, resolved()} | {:error, {:invalid_destination, reason()}}
  def resolve(destination, base_dir) when is_binary(destination) and is_binary(base_dir) do
    Assert.condition(Path.type(base_dir) == :absolute, "base_dir must be absolute: #{base_dir}")

    with :ok <- check_shape(destination),
         segments = String.split(destination, "/"),
         :ok <- check_depth(segments),
         :ok <- check_segments(segments),
         {:ok, path} <- join_under(destination, base_dir) do
      {:ok, %{segments: segments, path: path}}
    else
      {:error, reason} -> {:error, {:invalid_destination, reason}}
    end
  end

  defp check_shape(""), do: {:error, :empty}

  defp check_shape(destination) do
    cond do
      byte_size(destination) > @destination_bytes_max -> {:error, :too_long}
      not String.valid?(destination) -> {:error, :not_utf8}
      String.contains?(destination, <<0>>) -> {:error, :nul_byte}
      Path.type(destination) != :relative -> {:error, :absolute}
      true -> :ok
    end
  end

  defp check_depth(segments) do
    if length(segments) <= @segment_count_max do
      :ok
    else
      {:error, :too_deep}
    end
  end

  defp check_segments(segments) do
    Enum.find_value(segments, :ok, fn segment ->
      cond do
        byte_size(segment) > @segment_bytes_max -> {:error, :segment_too_long}
        not Regex.match?(@segment_pattern, segment) -> {:error, :segment_invalid}
        true -> nil
      end
    end)
  end

  # Path.safe_relative/2 backs up the segment allowlist: the two checks are
  # independent paths to the same no-escape property.
  defp join_under(destination, base_dir) do
    case Path.safe_relative(destination, base_dir) do
      {:ok, safe} ->
        path = Path.join(base_dir, safe)
        Assert.condition(String.starts_with?(path, base_dir <> "/"), "path escaped base: #{path}")
        {:ok, path}

      :error ->
        {:error, :traversal}
    end
  end
end
