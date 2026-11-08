defmodule Gobusgo.Routing.SnapshotFormatTest do
  # Verifies the packed format against the shared fixtures the JavaScript
  # reader is checked with: encoding the fixture records must give the
  # fixture files byte for byte, and decoding the files must give the records
  # back. The refusals alter a valid file one byte at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Routing.SnapshotFormat
  alias Gobusgo.Test.RoutingSnapshotFixture

  @kinds [:stops, :trips, :transfers, :connections]

  defp fixture(kind), do: File.read!(Path.join(RoutingSnapshotFixture.directory(), "#{kind}.bin"))
  defp records(kind), do: Map.fetch!(RoutingSnapshotFixture.records(), kind)

  for kind <- @kinds do
    test "encodes the #{kind} fixture records to the fixture file" do
      assert SnapshotFormat.encode(unquote(kind), records(unquote(kind))) ==
               fixture(unquote(kind))
    end

    test "decodes the #{kind} fixture file to its records" do
      assert SnapshotFormat.decode(fixture(unquote(kind))) ==
               {:ok, %{kind: unquote(kind), records: records(unquote(kind))}}
    end
  end

  test "the expected records the JavaScript reader compares with are the fixture records" do
    expected =
      RoutingSnapshotFixture.directory()
      |> Path.join("expected.json")
      |> File.read!()
      |> JSON.decode!()

    assert expected == RoutingSnapshotFixture.expected()
  end

  test "refuses a file with another magic" do
    <<_magic::binary-size(4), rest::binary>> = fixture(:stops)

    assert SnapshotFormat.decode("XXXX" <> rest) == {:error, :invalid_header}
  end

  test "refuses a file of another format version" do
    <<magic::binary-size(4), _version::little-16, rest::binary>> = fixture(:stops)

    assert SnapshotFormat.decode(magic <> <<2::little-16>> <> rest) ==
             {:error, :unsupported_version}
  end

  test "refuses a file of an unknown kind" do
    <<start::binary-size(6), _kind::little-16, rest::binary>> = fixture(:stops)

    assert SnapshotFormat.decode(start <> <<9::little-16>> <> rest) == {:error, :invalid_header}
  end

  test "refuses a file cut short" do
    for kind <- @kinds do
      file = fixture(kind)

      assert SnapshotFormat.decode(binary_part(file, 0, byte_size(file) - 1)) ==
               {:error, :invalid_length}
    end
  end

  test "refuses a file with a byte past its records" do
    for kind <- @kinds do
      assert SnapshotFormat.decode(fixture(kind) <> <<0>>) == {:error, :invalid_length}
    end
  end

  test "refuses a stop identifier that is not UTF-8" do
    file = SnapshotFormat.encode(:stops, ["ab"])
    altered = binary_part(file, 0, byte_size(file) - 2) <> <<0xFF, 0xFE>>

    assert SnapshotFormat.decode(altered) == {:error, :invalid_length}
  end
end
