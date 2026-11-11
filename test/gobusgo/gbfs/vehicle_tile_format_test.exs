defmodule Gobusgo.Gbfs.VehicleTileFormatTest do
  # Encodes blocks of vehicles the test writes out and decodes them back,
  # encodes the vehicles of `shared_vehicle_block.json` to the bytes of the
  # fixture the JavaScript decoder's check reads, which reads its expected
  # values from the same JSON, so the two readers of the format agree byte
  # for byte, and decodes broken blocks to the rule each breaks.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.VehicleTileFormat

  @fixture_path Path.expand("../../fixtures/gbfs/shared_vehicle_block.bin", __DIR__)
  @fixture_json_path Path.expand("../../fixtures/gbfs/shared_vehicle_block.json", __DIR__)
  @external_resource @fixture_json_path

  # The block the fixture holds, a tile's worth of bounds over Capitol Hill
  # with one vehicle of each form factor, one of them with no published
  # range and one past the largest range stored.
  @fixture_json @fixture_json_path |> File.read!() |> JSON.decode!()

  # The format's own form factors keyed by the names the fixture spells them
  # with; `Map.fetch!/2` fails on a name the format does not know.
  @form_factors_by_name Map.new(Map.keys(VehicleTileFormat.form_codes()), fn form_factor ->
                          {Atom.to_string(form_factor), form_factor}
                        end)

  @bounds %{
    south_microdegrees: @fixture_json["bounds"]["south"],
    west_microdegrees: @fixture_json["bounds"]["west"],
    north_microdegrees: @fixture_json["bounds"]["north"],
    east_microdegrees: @fixture_json["bounds"]["east"]
  }

  @fixture_block %{
    bounds: @bounds,
    vehicles:
      for vehicle <- @fixture_json["vehicles"] do
        %{
          lat: vehicle["lat"],
          lon: vehicle["lon"],
          current_range_meters: vehicle["currentRangeMeters"],
          form_factor: Map.fetch!(@form_factors_by_name, vehicle["formFactor"])
        }
      end
  }

  # One step of a stored fraction across the fixture's bounds, in degrees.
  @step_degrees 0.044 / 0xFFFF

  test "encodes the fixture block to the fixture's bytes" do
    assert VehicleTileFormat.encode(@fixture_block) == File.read!(@fixture_path)
  end

  test "decodes each position to within a step of where it was" do
    {:ok, %{vehicles: decoded}} =
      @fixture_block |> VehicleTileFormat.encode() |> VehicleTileFormat.decode()

    for {vehicle, decoded} <- Enum.zip(@fixture_block.vehicles, decoded) do
      assert_in_delta decoded.lat, vehicle.lat, @step_degrees
      assert_in_delta decoded.lon, vehicle.lon, @step_degrees
    end
  end

  test "decodes ranges to the decameter and an unpublished range as none" do
    {:ok, %{vehicles: decoded}} =
      @fixture_block |> VehicleTileFormat.encode() |> VehicleTileFormat.decode()

    assert Enum.map(decoded, & &1.current_range_meters) == [34_250, 3_780, nil, 655_340, 0]
    assert @fixture_json["decodedRangesMeters"] == [34_250, 3_780, nil, 655_340, 0]
  end

  test "decodes every form factor as it was encoded" do
    {:ok, %{vehicles: decoded}} =
      @fixture_block |> VehicleTileFormat.encode() |> VehicleTileFormat.decode()

    assert Enum.map(decoded, & &1.form_factor) ==
             Enum.map(@fixture_block.vehicles, & &1.form_factor)
  end

  test "stores a position outside the bounds at the nearest edge" do
    outside = %{lat: 48.0, lon: -123.0, current_range_meters: nil, form_factor: :other}
    block = VehicleTileFormat.encode(%{bounds: @bounds, vehicles: [outside]})

    {:ok, %{vehicles: [decoded]}} = VehicleTileFormat.decode(block)

    assert {decoded.lat, decoded.lon} == {47.636, -122.344}
  end

  test "encodes and decodes a block with no vehicles" do
    block = VehicleTileFormat.encode(%{bounds: @bounds, vehicles: []})

    assert VehicleTileFormat.decode(block) == {:ok, %{bounds: @bounds, vehicles: []}}
  end

  test "stores every position of a block with no width at its west edge" do
    bounds = %{@bounds | east_microdegrees: @bounds.west_microdegrees}
    vehicle = %{lat: 47.62, lon: -122.344, current_range_meters: nil, form_factor: :other}
    block = VehicleTileFormat.encode(%{bounds: bounds, vehicles: [vehicle]})

    {:ok, %{vehicles: [decoded]}} = VehicleTileFormat.decode(block)

    assert decoded.lon == -122.344
  end

  test "refuses to encode bounds whose south is over their north" do
    bounds = %{@bounds | south_microdegrees: 47_700_000}

    assert_raise Gobusgo.Assert.AssertionError, fn ->
      VehicleTileFormat.encode(%{bounds: bounds, vehicles: []})
    end
  end

  describe "decode/1 refuses" do
    setup do
      %{block: VehicleTileFormat.encode(@fixture_block)}
    end

    test "another magic", %{block: <<_magic::binary-size(4), rest::binary>>} do
      assert VehicleTileFormat.decode("XXXX" <> rest) == {:error, :magic}
    end

    test "another version", %{block: <<magic::binary-size(4), _version::16, rest::binary>>} do
      assert VehicleTileFormat.decode(magic <> <<2::little-16>> <> rest) == {:error, :version}
    end

    test "a block cut short", %{block: block} do
      assert VehicleTileFormat.decode(binary_part(block, 0, byte_size(block) - 1)) ==
               {:error, :length}
    end

    test "a header cut short", %{block: block} do
      assert VehicleTileFormat.decode(binary_part(block, 0, 10)) == {:error, :length}
    end

    test "bounds outside their axis", %{block: block} do
      <<head::binary-size(12), _south::32, rest::binary>> = block

      assert VehicleTileFormat.decode(head <> <<-91_000_000::little-signed-32>> <> rest) ==
               {:error, :bounds}
    end

    test "a form code it does not know", %{block: block} do
      broken = binary_part(block, 0, byte_size(block) - 1) <> <<9>>

      assert VehicleTileFormat.decode(broken) == {:error, :form_factor}
    end
  end
end
