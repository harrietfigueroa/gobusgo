defmodule Gobusgo.Gbfs.VehicleTileSetTest do
  # Verifies build/1 as a pure function of one fetch and the vehicle types:
  # the fetch holds vehicles the test places, with Lime Seattle's recorded
  # 2.2 types, and each case reads the files back through the format's
  # decoder and the index's JSON.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.VehicleTileFormat
  alias Gobusgo.Gbfs.VehicleTileSet
  alias Gobusgo.Gbfs.VehicleTypeRecords

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @type_request_id "0199c4a2-7e1b-7a3f-9d20-000000000002"
  @fetched_at ~U[2026-11-08 19:08:30Z]
  @directory "shared-vehicles/dt=2026-11-08/system=lime_seattle/20261108T190830Z_#{@request_id}/"

  # Westlake and the University District fall in two tiles of zoom 14, and
  # the two vehicles at Westlake share one.
  @westlake %{lat: 47.6114, lon: -122.3370}
  @westlake_too %{lat: 47.6120, lon: -122.3380}
  @university_district %{lat: 47.6614, lon: -122.3130}

  defp type_fetches do
    document =
      @fixture_directory
      |> Path.join("lime_v2_vehicle_types.json")
      |> File.read!()
      |> JSON.decode!()

    {:ok, %{vehicle_types: types}} = Files.vehicle_types(%{version: "2.2", document: document})

    record =
      VehicleTypeRecords.build(%{
        system_id: "lime_seattle",
        version: "2.2",
        request_id: @type_request_id,
        fetched_at: ~U[2026-11-08 19:00:00Z],
        vehicle_types: types
      })

    {:ok, decoded} = VehicleTypeRecords.decode(record.value)
    [decoded]
  end

  defp vehicle(position, overrides \\ %{}) do
    Map.merge(
      %{
        id: "bike-#{System.unique_integer([:positive])}",
        position: position,
        vehicle_type_id: "2",
        current_range_meters: 12_000,
        is_disabled: false,
        is_reserved: false,
        last_reported: nil
      },
      overrides
    )
  end

  defp fetched(vehicles) do
    %{
      kind: :fetched,
      id: "lime_seattle",
      version: "2.2",
      last_updated: ~U[2026-11-08 19:08:00Z],
      ttl: 60,
      vehicles: vehicles,
      data_sha256: String.duplicate("0", 64),
      destination: "raw/gbfs/free-bike-status/test",
      fetched_at: @fetched_at,
      request_id: @request_id
    }
  end

  defp build(vehicles) do
    VehicleTileSet.build(%{fetched: fetched(vehicles), type_fetches: type_fetches()})
  end

  defp index(set), do: set.index.content |> JSON.decode!()

  defp decoded(file) do
    {:ok, block} = VehicleTileFormat.decode(file.content)
    block
  end

  defp file_named(set, name), do: Enum.find(set.files, &String.ends_with?(&1.destination, name))

  defp tile_file(set, [x, y, _count, hash]) do
    file_named(set, "tile-14-#{x}-#{y}-#{hash}.bin.gz")
  end

  test "writes one tile per tile of zoom 14 that holds a vehicle" do
    set = build([vehicle(@westlake), vehicle(@westlake_too), vehicle(@university_district)])

    assert Enum.map(index(set)["tiles"], fn [x, y, count, _hash] -> {x, y, count} end) ==
             [{2624, 5721, 2}, {2625, 5718, 1}]
  end

  test "places each tile's vehicles inside the tile's bounds" do
    set = build([vehicle(@westlake), vehicle(@westlake_too), vehicle(@university_district)])

    for entry <- index(set)["tiles"] do
      %{bounds: bounds, vehicles: vehicles} = decoded(tile_file(set, entry))

      for %{lat: lat, lon: lon} <- vehicles do
        assert lat * 1_000_000 >= bounds.south_microdegrees
        assert lat * 1_000_000 <= bounds.north_microdegrees
        assert lon * 1_000_000 >= bounds.west_microdegrees
        assert lon * 1_000_000 <= bounds.east_microdegrees
      end
    end
  end

  test "names the tile a Web Mercator position falls in" do
    assert VehicleTileSet.tile_of(@westlake) == %{x: 2624, y: 5721}
  end

  test "writes every published vehicle to the whole-city file" do
    set = build([vehicle(@westlake), vehicle(@university_district)])

    city = file_named(set, index(set)["city"])

    assert length(decoded(city).vehicles) == 2
  end

  test "gives each vehicle the form factor of its type" do
    set = build([vehicle(@westlake), vehicle(@university_district, %{vehicle_type_id: "3"})])

    city = file_named(set, index(set)["city"])

    assert Enum.map(decoded(city).vehicles, & &1.form_factor) == [:standing_scooter, :e_bike]
  end

  test "keeps a vehicle's remaining range" do
    set = build([vehicle(@westlake, %{current_range_meters: 3_782})])

    city = file_named(set, index(set)["city"])

    assert [%{current_range_meters: 3_780}] = decoded(city).vehicles
  end

  for {name, overrides} <- [
        {"disabled", %{is_disabled: true}},
        {"reserved", %{is_reserved: true}},
        {"without a position", %{position: nil}}
      ] do
    test "leaves out a vehicle #{name}" do
      set =
        build([
          vehicle(@westlake),
          vehicle(@university_district, unquote(Macro.escape(overrides)))
        ])

      assert index(set)["vehicleCount"] == 1
    end
  end

  test "holds no vehicle identifier in any file" do
    vehicles = [vehicle(@westlake, %{id: "c7629d49-identifier"})]
    set = build(vehicles)

    for file <- [set.index | set.files] do
      refute file.content =~ "c7629d49"
    end
  end

  test "puts every file in the fetch's directory" do
    set = build([vehicle(@westlake)])

    assert Enum.all?([set.index | set.files], &String.starts_with?(&1.destination, @directory))
  end

  test "names each file by the hash of its content" do
    set = build([vehicle(@westlake)])

    for file <- [set.index | set.files] do
      hash = :sha256 |> :crypto.hash(file.content) |> Base.encode16(case: :lower)
      assert file.destination =~ binary_part(hash, 0, 16)
    end
  end

  test "builds the same files from the same fetch" do
    vehicles = [vehicle(@westlake), vehicle(@university_district)]

    assert build(vehicles) == build(vehicles)
  end

  test "states the fetch in the index" do
    set = build([vehicle(@westlake)])

    assert Map.take(index(set), ["systemId", "version", "fetchedAt", "tileZoom", "formatVersion"]) ==
             %{
               "systemId" => "lime_seattle",
               "version" => "2.2",
               "fetchedAt" => "2026-11-08T19:08:30Z",
               "tileZoom" => 14,
               "formatVersion" => 1
             }
  end

  # The JavaScript reader's check reads the index fixture as an index this
  # module writes.
  test "writes an index with the keys of the index fixture" do
    fixture =
      @fixture_directory
      |> Path.join("shared_vehicle_index.json")
      |> File.read!()
      |> JSON.decode!()

    set = build([vehicle(@westlake)])

    assert Enum.sort(Map.keys(index(set))) == Enum.sort(Map.keys(fixture))
  end

  test "builds an index with no tiles for a fetch with no vehicles" do
    set = build([])

    assert {index(set)["tiles"], index(set)["vehicleCount"], set.tile_count} == {[], 0, 0}
  end

  test "reads the fetch each file belongs to from its destination" do
    set = build([vehicle(@westlake)])

    for file <- [set.index | set.files] do
      assert VehicleTileSet.parse_destination(file.destination) ==
               {:ok,
                %{system_id: "lime_seattle", fetched_at: @fetched_at, request_id: @request_id}}
    end
  end

  for destination <- [
        "shared-vehicles/dt=2026-11-08/system=lime_seattle/other/index-0.json.gz",
        "shared-vehicles/dt=2026-11-07/system=lime_seattle/20261108T190830Z_#{@request_id}/city-0.bin.gz",
        "raw/gbfs/free-bike-status/dt=2026-11-08/system=lime_seattle/x.json.gz",
        "shared-vehicles/dt=2026-11-08/system=lime_seattle/20261108T190830Z_#{@request_id}/notes.txt"
      ] do
    test "reads no fetch from #{destination}" do
      assert VehicleTileSet.parse_destination(unquote(destination)) == :error
    end
  end
end
