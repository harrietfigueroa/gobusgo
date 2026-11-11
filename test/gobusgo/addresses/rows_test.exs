defmodule Gobusgo.Addresses.RowsTest do
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Rows

  defp address(number, suffix, lat, lon) do
    %{number: number, suffix: suffix, lat_microdegrees: lat, lon_microdegrees: lon}
  end

  test "a row is thirteen bytes and unpacks to the address it holds" do
    original = address(920, "B", 47_606_200, -122_332_100)
    packed = Rows.pack(original)

    assert byte_size(packed) == Rows.row_bytes()
    assert Rows.unpack(packed) == [original]
  end

  test "a negative longitude and a house number past a signed 32-bit integer survive a round trip" do
    original = address(4_000_000_000, "", -1, -2_147_483_648)
    assert original |> Rows.pack() |> Rows.unpack() == [original]
  end

  test "microdegrees rounds to the nearest and refuses a position off the globe" do
    assert Rows.microdegrees(%{lat: 47.6062004, lon: -122.3321006}) ==
             {:ok, %{lat: 47_606_200, lon: -122_332_101}}

    assert Rows.microdegrees(%{lat: 91.0, lon: 0.0}) == :invalid
    assert Rows.microdegrees(%{lat: 0.0, lon: -181.0}) == :invalid
  end

  test "merge sorts by number then suffix and joins the rows of one address at their mean" do
    rows =
      IO.iodata_to_binary([
        Rows.pack(address(20, "", 200, 200)),
        Rows.pack(address(10, "B", 100, 100)),
        Rows.pack(address(10, "", 10, 20)),
        Rows.pack(address(10, "", 11, 23)),
        Rows.pack(address(10, "A", 100, 100))
      ])

    assert rows |> Rows.merge() |> Rows.unpack() == [
             address(10, "", 11, 22),
             address(10, "A", 100, 100),
             address(10, "B", 100, 100),
             address(20, "", 200, 200)
           ]
  end

  test "a row count follows the byte size" do
    rows = IO.iodata_to_binary([Rows.pack(address(1, "", 0, 0)), Rows.pack(address(2, "", 0, 0))])
    assert Rows.count(rows) == 2
  end

  test "bytes that are no whole count of rows fail an assertion" do
    assert_raise Gobusgo.Assert.AssertionError, fn -> Rows.unpack(<<1, 2, 3>>) end
  end
end
