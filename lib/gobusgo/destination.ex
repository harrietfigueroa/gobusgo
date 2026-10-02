defmodule Gobusgo.Destination do
  @destination_bytes_max 1024
  @segment_bytes_max 128
  @segment_count_max 16

  @moduledoc """
  The rules every logical destination obeys, whatever stores it: a non-empty,
  relative, valid UTF-8 name without NUL bytes, made of `/`-separated segments
  that match an allowlist, with bounded length and depth. Everything here is
  pure.

  A segment is 1 to #{@segment_bytes_max} bytes of `A-Z`, `a-z`, `0-9`, `.`,
  `_`, `=` and `-`, and does not start with `.`. A destination is at most
  #{@destination_bytes_max} bytes and #{@segment_count_max} segments.

  A prefix selects every destination that starts with it, compared as a
  string. It obeys the same rules, except that its last segment may be
  incomplete, or empty when the prefix ends in `/`.
  """

  # The first character excludes `.` so that hidden names fail.
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
    :traversal
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

  @type prefix :: %{segments: [String.t()], remainder: String.t()}

  @doc "Every reason a destination or a prefix can be rejected for."
  @spec reasons() :: [reason(), ...]
  def reasons, do: @reasons

  @doc "Segments allowed in one destination."
  @spec segment_count_max() :: pos_integer()
  def segment_count_max, do: @segment_count_max

  @doc """
  Returns the segments of a valid `destination`, or the first rule it breaks.
  A `.` or `..` segment is a traversal; a leading `/` is absolute.
  """
  @spec validate(String.t()) ::
          {:ok, [String.t(), ...]} | {:error, {:invalid_destination, reason()}}
  def validate(destination) when is_binary(destination) do
    with :ok <- check_shape(destination),
         segments = String.split(destination, "/"),
         :ok <- check_depth(segments),
         :ok <- check_segments(segments) do
      {:ok, segments}
    else
      {:error, reason} -> {:error, {:invalid_destination, reason}}
    end
  end

  @doc """
  Returns the complete leading segments of a valid `prefix` and the remainder
  after the last `/`, or the first rule the prefix breaks. The remainder is
  `""` when the prefix ends in `/`. The empty prefix is rejected as `:empty`.
  """
  @spec validate_prefix(String.t()) ::
          {:ok, prefix()} | {:error, {:invalid_destination, reason()}}
  def validate_prefix(prefix) when is_binary(prefix) do
    with :ok <- check_shape(prefix),
         parts = String.split(prefix, "/"),
         :ok <- check_depth(parts),
         {segments, [remainder]} = Enum.split(parts, -1),
         :ok <- check_segments(segments),
         :ok <- check_remainder(remainder) do
      {:ok, %{segments: segments, remainder: remainder}}
    else
      {:error, reason} -> {:error, {:invalid_destination, reason}}
    end
  end

  defp check_remainder(""), do: :ok
  defp check_remainder(remainder), do: check_segments([remainder])

  defp check_shape(""), do: {:error, :empty}

  defp check_shape(destination) do
    cond do
      byte_size(destination) > @destination_bytes_max -> {:error, :too_long}
      not String.valid?(destination) -> {:error, :not_utf8}
      String.contains?(destination, <<0>>) -> {:error, :nul_byte}
      String.starts_with?(destination, "/") -> {:error, :absolute}
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
        segment in [".", ".."] -> {:error, :traversal}
        byte_size(segment) > @segment_bytes_max -> {:error, :segment_too_long}
        not Regex.match?(@segment_pattern, segment) -> {:error, :segment_invalid}
        true -> nil
      end
    end)
  end
end
