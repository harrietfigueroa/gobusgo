defmodule Gobusgo.CompressionTest do
  # Verifies compression as pure functions of their input: compressed bytes
  # are checked against the gzip format and Erlang's own decoder, and each
  # refused input is built by hand from a valid stream.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression

  @gzip_magic <<0x1F, 0x8B>>

  describe "compressed?/1" do
    for {name, destination, expected} <- [
          {"a name that ends in the suffix", "raw/a.json.gz", true},
          {"a name without the suffix", "raw/a.json", false},
          {"a name that holds the suffix elsewhere", "raw/a.gz.json", false},
          {"a name that ends in the letters alone", "raw/agz", false}
        ] do
      test "is #{expected} for #{name}" do
        assert Compression.compressed?(unquote(destination)) == unquote(expected)
      end
    end
  end

  describe "compress/1" do
    test "returns a gzip stream that a standard decoder restores" do
      content = ~s({"meta":{},"body":{}})
      compressed = Compression.compress(content)

      assert <<@gzip_magic, _rest::binary>> = compressed
      assert :zlib.gunzip(compressed) == content
    end

    test "compresses the empty binary to a stream that restores it" do
      assert :zlib.gunzip(Compression.compress("")) == ""
    end

    test "shrinks repetitive content" do
      content = String.duplicate(~s({"vehicleId":"1_4207"},), 1000)

      assert byte_size(Compression.compress(content)) < div(byte_size(content), 10)
    end
  end

  describe "decompress/2" do
    test "restores what compress/1 produced" do
      content = :crypto.strong_rand_bytes(4096)

      assert Compression.decompress(Compression.compress(content), 4096) == {:ok, content}
    end

    test "restores content larger than one inflate chunk" do
      content = String.duplicate("0123456789abcdef", 64 * 1024)

      assert Compression.decompress(Compression.compress(content), byte_size(content)) ==
               {:ok, content}
    end

    test "restores the empty binary" do
      assert Compression.decompress(Compression.compress(""), 1) == {:ok, ""}
    end

    test "refuses content that expands past the limit" do
      content = String.duplicate("a", 1025)

      assert Compression.decompress(Compression.compress(content), 1024) == {:error, :too_large}
    end

    test "refuses a highly compressed stream without expanding all of it" do
      bomb = Compression.compress(:binary.copy(<<0>>, 64 * 1024 * 1024))

      assert Compression.decompress(bomb, 1024) == {:error, :too_large}
    end

    for {name, build} <- [
          {"the empty binary", quote(do: fn _valid -> "" end)},
          {"plain text", quote(do: fn _valid -> ~s({"meta":{}}) end)},
          {"a stream cut short",
           quote(do: fn valid -> binary_part(valid, 0, byte_size(valid) - 9) end)},
          {"a stream with a flipped checksum",
           quote do
             fn valid ->
               size = byte_size(valid) - 8
               <<head::binary-size(^size), crc::32, length::32>> = valid
               <<head::binary, Bitwise.bxor(crc, 1)::32, length::32>>
             end
           end},
          {"a zlib stream without the gzip wrapper",
           quote(do: fn _valid -> :zlib.compress("content") end)}
        ] do
      test "refuses #{name} as corrupt" do
        valid = Compression.compress(String.duplicate("content ", 100))
        input = unquote(build).(valid)

        assert Compression.decompress(input, 4096) == {:error, :corrupt}
      end
    end

    test "raises on a limit below one byte" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Compression.decompress(Compression.compress("a"), 0)
      end
    end
  end
end
