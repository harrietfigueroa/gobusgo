defmodule Gobusgo.Compression do
  @content_bytes_max 16 * 1024 * 1024
  @suffix ".gz"

  @moduledoc """
  The compression of stored content: which logical destinations hold
  compressed content, and the gzip encoding and decoding of it. Everything
  here is pure.

  A destination that ends in `#{@suffix}` holds content compressed as one
  gzip stream (RFC 1952). Every other destination holds content as it is.
  Compressed content is at most #{@content_bytes_max} bytes before
  compression.
  """

  alias Gobusgo.Assert

  # A window of 2^15 bytes, plus 16, which makes inflate decode the gzip
  # format alone.
  # https://zlib.net/manual.html (inflateInit2) — checked 2026-10-03
  @gzip_window_bits 16 + 15

  @typedoc """
    * `:corrupt` — the input is not one complete gzip stream.
    * `:too_large` — the stream expands past the limit.
  """
  @type decompress_error :: :corrupt | :too_large

  @doc "Bytes allowed in content that is stored compressed, before compression."
  @spec content_bytes_max() :: pos_integer()
  def content_bytes_max, do: @content_bytes_max

  @doc "The ending of every destination that holds compressed content."
  @spec suffix() :: String.t()
  def suffix, do: @suffix

  @doc "Whether `destination` holds compressed content."
  @spec compressed?(String.t()) :: boolean()
  def compressed?(destination) when is_binary(destination) do
    String.ends_with?(destination, @suffix)
  end

  @doc "Returns `content` as one gzip stream."
  @spec compress(binary()) :: binary()
  def compress(content) when is_binary(content) do
    compressed = :zlib.gzip(content)
    Assert.condition(is_binary(compressed), "gzip must return a binary")
    compressed
  end

  @doc """
  Returns the content of the gzip stream `compressed`, which expands to at
  most `bytes_max` bytes. Expansion stops once the limit is passed, so a small
  stream cannot claim unbounded memory.
  """
  @spec decompress(binary(), pos_integer()) :: {:ok, binary()} | {:error, decompress_error()}
  def decompress(compressed, bytes_max) when is_binary(compressed) do
    Assert.condition(is_integer(bytes_max), "limit must be an integer")
    Assert.condition(bytes_max >= 1, "limit must be at least 1 byte, got: #{bytes_max}")
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, @gzip_window_bits)
      inflate(stream, :zlib.safeInflate(stream, compressed), %{chunks: [], bytes_left: bytes_max})
    rescue
      # zlib raises `:data_error` for a malformed stream, a failed checksum,
      # and a stream that ends early; any other error is not this input's.
      error in ErlangError ->
        case error.original do
          :data_error -> {:error, :corrupt}
          _other -> reraise error, __STACKTRACE__
        end
    after
      :zlib.close(stream)
    end
  end

  # Only the zlib format can ask for a preset dictionary; the gzip format has
  # no field for one.
  # https://www.erlang.org/doc/apps/erts/zlib.html#safeInflate/2 — checked 2026-10-03
  defp inflate(_stream, {:need_dictionary, _adler, _output}, _progress), do: {:error, :corrupt}

  defp inflate(stream, {step, output}, %{chunks: chunks, bytes_left: bytes_left}) do
    bytes = IO.iodata_length(output)

    if bytes <= bytes_left do
      progress = %{chunks: [chunks, output], bytes_left: bytes_left - bytes}

      case step do
        :continue ->
          # Each further step yields output, which the limit then bounds.
          Assert.condition(bytes > 0, "inflate must make progress")
          inflate(stream, :zlib.safeInflate(stream, []), progress)

        :finished ->
          # Raises `:data_error` when the stream ended before its trailer.
          :ok = :zlib.inflateEnd(stream)
          {:ok, IO.iodata_to_binary(progress.chunks)}
      end
    else
      {:error, :too_large}
    end
  end
end
