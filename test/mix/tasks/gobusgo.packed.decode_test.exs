defmodule Mix.Tasks.Gobusgo.Packed.DecodeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.Test.PackedFixture
  alias Mix.Tasks.Gobusgo.Packed.Decode

  # The task prints what the decoder reads from a stored stream and from the
  # expanded bytes alike.

  defp input(file, bytes),
    do: %{file: file, bytes: bytes, bytes_max: Compression.content_bytes_max()}

  test "a stream and its expanded bytes give one description" do
    expanded = PackedFixture.encode()
    {:ok, from_stream} = Decode.describe(input("x.bin.gz", Compression.compress(expanded)))
    {:ok, from_bytes} = Decode.describe(input("x.bin", expanded))

    assert from_stream == from_bytes
  end

  test "the description holds the header, the strings, and each section's length" do
    {:ok, decoded} = Decode.describe(input("x.bin", PackedFixture.encode()))
    description = Decode.description(decoded)

    assert %{"kind" => 0, "version" => 1, "recordCount" => 5} = description
    assert length(description["strings"]) == 4
    assert length(description["sections"]) == PackedFixture.section_count()
    assert %{"byteLength" => 20, "base64" => _bytes} = hd(description["sections"])
  end

  test "a file past the bound is refused" do
    stream = Compression.compress(PackedFixture.encode())

    assert Decode.describe(%{file: "x.bin.gz", bytes: stream, bytes_max: 16}) ==
             {:error, :too_large}
  end

  test "a file that is not a container is refused" do
    assert Decode.describe(input("x.bin", String.duplicate("x", 32))) == {:error, :bad_magic}
  end
end
