defmodule Gobusgo.ReaderWriterTest do
  # Verifies that the configured writer and reader backends agree: content
  # stored through Gobusgo.Writer is discovered and read back through
  # Gobusgo.Reader under the same logical destination. Both entry points use
  # the application's configured backends against a temporary base directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @destination "raw/oba/agencies-with-coverage/dt=2026-10-02/20261002T031500Z_0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10_3f9a1c07be52.json"

  test "reads back the content the writer stored", %{tmp_dir: tmp_dir} do
    content = ~s({"meta":{},"body":{}})
    :ok = Writer.write(%{destination: @destination, content: content}, base_dir: tmp_dir)

    assert Reader.read(@destination, base_dir: tmp_dir) == {:ok, content}
  end

  test "stores a compressed destination as a gzip file and reads the content back", %{
    tmp_dir: tmp_dir
  } do
    destination = @destination <> ".gz"
    content = String.duplicate(~s({"meta":{},"body":{}}), 100)
    :ok = Writer.write(%{destination: destination, content: content}, base_dir: tmp_dir)

    stored = File.read!(Path.join(tmp_dir, destination))
    assert byte_size(stored) < byte_size(content)
    assert :zlib.gunzip(stored) == content
    assert Reader.read(destination, base_dir: tmp_dir) == {:ok, content}
  end

  test "discovers the destination the writer stored and nothing else", %{tmp_dir: tmp_dir} do
    :ok = Writer.write(%{destination: @destination, content: "x"}, base_dir: tmp_dir)

    request = %{
      prefix: "raw/oba/agencies-with-coverage/",
      limit: 10,
      order: :ascending,
      cursor: nil
    }

    assert Reader.discover(request, base_dir: tmp_dir) ==
             {:ok, %{destinations: [@destination], cursor: nil}}
  end

  test "rejects a destination with the reason the writer gives", %{tmp_dir: tmp_dir} do
    invalid = "raw/../escape.json"
    written = Writer.write(%{destination: invalid, content: "x"}, base_dir: tmp_dir)

    assert written == {:error, {:invalid_destination, :traversal}}
    assert Reader.read(invalid, base_dir: tmp_dir) == written
  end
end
