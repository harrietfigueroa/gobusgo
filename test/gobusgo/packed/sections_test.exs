defmodule Gobusgo.Packed.SectionsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.StringTable
  alias Gobusgo.Packed.Varint

  # The readers and writers of what a section holds: varints, columns,
  # positions, paths, and the string table.

  describe "varint" do
    for {value, bytes} <- [
          {0, <<0>>},
          {127, <<127>>},
          {128, <<0x80, 0x01>>},
          {16_383, <<0xFF, 0x7F>>},
          {16_384, <<0x80, 0x80, 0x01>>},
          {4_294_967_295, <<0xFF, 0xFF, 0xFF, 0xFF, 0x0F>>}
        ] do
      test "#{value} is #{inspect(bytes)} and reads back" do
        assert Varint.encode(unquote(value)) == unquote(bytes)
        assert Varint.decode(unquote(bytes) <> "rest") == {:ok, unquote(value), "rest"}
      end
    end

    test "a sixth byte is refused" do
      assert Varint.decode(<<0x80, 0x80, 0x80, 0x80, 0x80, 0x01>>) == {:error, :bad_varint}
    end

    test "a value past 32 bits is refused" do
      assert Varint.decode(<<0xFF, 0xFF, 0xFF, 0xFF, 0x1F>>) == {:error, :bad_varint}
    end

    test "a varint cut short is truncated" do
      assert Varint.decode(<<0x80>>) == {:error, :truncated}
      assert Varint.decode(<<>>) == {:error, :truncated}
    end

    test "the encoder refuses a negative value and one past 32 bits" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> Varint.encode(-1) end
      assert_raise Gobusgo.Assert.AssertionError, fn -> Varint.encode(4_294_967_296) end
    end
  end

  describe "zigzag" do
    for {integer, value} <- [
          {0, 0},
          {-1, 1},
          {1, 2},
          {-2, 3},
          {2_147_483_647, 4_294_967_294},
          {-2_147_483_647, 4_294_967_293}
        ] do
      test "#{integer} is #{value}" do
        assert Varint.zigzag(unquote(integer)) == unquote(value)
        assert Varint.unzigzag(unquote(value)) == unquote(integer)
      end
    end
  end

  describe "columns" do
    for {type, values} <- [
          u8: [0, 255],
          u16: [0, 65_535],
          u32: [0, 4_294_967_295],
          i32: [-2_147_483_648, -1, 0, 2_147_483_647]
        ] do
      test "a #{type} column reads back" do
        section = Columns.encode(unquote(type), unquote(values))
        assert byte_size(section) == length(unquote(values)) * Columns.width(unquote(type))

        assert Columns.decode(unquote(type), section, length(unquote(values))) ==
                 {:ok, unquote(values)}
      end
    end

    test "a section of another size than the count is refused" do
      assert Columns.decode(:u32, <<1, 0, 0, 0>>, 2) == {:error, :bad_section_size}
    end

    test "the encoder refuses a value out of range" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> Columns.encode(:u8, [256]) end
      assert_raise Gobusgo.Assert.AssertionError, fn -> Columns.encode(:i32, [2_147_483_648]) end
    end
  end

  describe "positions" do
    test "known and unknown positions read back" do
      positions = [{47_606_200, -122_332_100}, :unknown, {-90_000_000, 180_000_000}]
      assert Positions.decode(Positions.encode(positions), 3) == {:ok, positions}
    end

    test "an unknown on one axis alone is refused" do
      section = <<Positions.unknown()::little-signed-32, 0::little-signed-32>>
      assert Positions.decode(section, 1) == {:error, :bad_position}
    end

    test "a latitude past 90 degrees is refused" do
      section = <<90_000_001::little-signed-32, 0::little-signed-32>>
      assert Positions.decode(section, 1) == {:error, :bad_position}
    end

    test "the encoder refuses a longitude past 180 degrees" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Positions.encode([{0, 180_000_001}])
      end
    end

    test "a path of negative and positive deltas and a long jump reads back" do
      path = [{47_606_200, -122_332_100}, {47_606_150, -122_332_000}, {-33_868_800, 151_209_300}]
      assert Positions.decode_path(Positions.encode_path(path) <> "x") == {:ok, path, "x"}
    end

    test "an empty path is one byte" do
      assert Positions.encode_path([]) == <<0>>
    end

    test "a path whose count its bytes cannot hold is truncated" do
      assert Positions.decode_path(<<5, 0, 0>>) == {:error, :truncated}
    end

    test "a path that leaves the globe is refused" do
      path = Varint.encode(1) <> Varint.encode(Varint.zigzag(90_000_001)) <> Varint.encode(0)
      assert Positions.decode_path(path) == {:error, :bad_position}
    end
  end

  describe "string table" do
    test "the builder numbers strings by first use and interns repeats" do
      {first, table} = StringTable.intern(StringTable.new(), "b")
      {second, table} = StringTable.intern(table, "a")
      {repeat, table} = StringTable.intern(table, "b")

      assert {first, second, repeat} == {0, 1, 0}
      assert StringTable.strings(table) == ["b", "a"]
    end

    test "entries including the empty string and multibyte text read back" do
      strings = ["", "Bothell–Everett", "東京"]
      assert StringTable.decode(StringTable.encode(strings)) == {:ok, strings}
    end
  end
end
