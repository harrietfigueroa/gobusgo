defmodule Gobusgo.Writer.Destination do
  @moduledoc """
  The rules every logical destination obeys, whatever the backend: a
  non-empty, relative, valid UTF-8 name without NUL bytes, made of
  `/`-separated segments that match an allowlist, with bounded length and
  depth. Everything here is pure.
  """

  @destination_bytes_max 1024
  @segment_bytes_max 128
  @segment_count_max 16

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

  @doc "Every reason a destination can be rejected for."
  @spec reasons() :: [reason(), ...]
  def reasons, do: @reasons

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
