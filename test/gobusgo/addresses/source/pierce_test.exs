defmodule Gobusgo.Addresses.Source.PierceTest do
  # Drives fetch/2 against a plug that answers as the county's FeatureServer
  # layer does (its description, its count, and its pages of features whose
  # values are rows of the real layer), and reads the records of the file the
  # fetch wrote. No request leaves the machine.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Source.Pierce
  alias Gobusgo.Test.FeatureLayer

  @moduletag :tmp_dir

  @layer_path "/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Address_Points/FeatureServer/0"
  @layer_last_edit_ms 1_793_967_773_886
  @header "HouseNumber,PrefixDirectional,StreetName,StreetType,PostDirectional,City,Status,x,y\n"

  # Rows of the layer as its query answered them on 2026-11-11: compound
  # types, a LOOP, a prefix directional, TEMPORARY points, and the nulls the
  # service gives for an empty prefix directional.
  @rows [
    {1, "611", nil, "3RD", "ST", "", "Steilacoom", "ACTIVE", -122.60899603847912,
     47.1663769816001},
    {513, "7218", nil, "45TH", "ST CT", "E", "Fife", "ACTIVE", -122.3318961645315,
     47.21532711294391},
    {2135, "406", nil, "25TH", "AVE PL", "", "Milton", "ACTIVE", -122.30087242613375,
     47.254259165664614},
    {266_645, "5568", nil, "34TH", "ST LP", "NE", "Tacoma", "ACTIVE", -122.37565363270177,
     47.28817785033674},
    {337, "2104", nil, "62ND", "LOOP", "SE", "Auburn", "ACTIVE", -122.20274060653425,
     47.25317088995783},
    {9, "110", nil, "UNION", "AVE", "", "Steilacoom", "TEMPORARY", -122.60336098587082,
     47.17096950275996},
    {122, "1811", nil, "NISQUALLY", "ST", "", "Steilacoom", "TEMPORARY", -122.59488254433343,
     47.171709165258065},
    {2347, "272", "E", "MASON", "AVE", "", "Buckley", "ACTIVE", -122.03420835386942,
     47.16187136375911}
  ]

  defp feature({object_id, number, prefix, name, type, suffix, city, status, x, y}) do
    %{
      "attributes" => %{
        "OBJECTID" => object_id,
        "HouseNumber" => number,
        "PrefixDirectional" => prefix,
        "StreetName" => name,
        "StreetType" => type,
        "PostDirectional" => suffix,
        "City" => city,
        "Status" => status
      },
      "geometry" => %{"x" => x, "y" => y}
    }
  end

  defp layer_features, do: @rows |> Enum.map(&feature/1) |> Enum.sort_by(&object_id/1)

  defp object_id(feature), do: feature["attributes"]["OBJECTID"]

  defp numbered(count) do
    [template | _rest] = layer_features()
    Enum.map(1..count, &put_in(template, ["attributes", "OBJECTID"], &1))
  end

  defp fetch(tmp_dir, features, options \\ []) do
    script = Keyword.get(options, :script, fn _conn -> :default end)

    Pierce.fetch(
      %{directory: tmp_dir, bytes_max: Keyword.get(options, :bytes_max, 1_000_000)},
      plug:
        FeatureLayer.plug(%{
          test_pid: self(),
          path: @layer_path,
          last_edit_ms: @layer_last_edit_ms,
          features: features,
          script: script
        }),
      retry_base_ms: 0
    )
  end

  defp records(export), do: export.path |> Pierce.records() |> Enum.to_list()

  test "pages the layer into a file and reports the layer's last edit and the count it read",
       %{tmp_dir: tmp_dir} do
    assert {:ok, export} = fetch(tmp_dir, numbered(250))

    assert export.last_edit_at == ~U[2026-11-06 12:22:53.886Z]
    assert export.record_count == 250
    assert export.byte_count == File.stat!(export.path).size
    assert length(records(export)) == 250
  end

  test "reads each feature as a record of the fields the build uses, at its WGS 84 geometry",
       %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, layer_features())

    assert hd(records(export)) == %{
             house_number: "611",
             pre_direction: "",
             name: "3RD",
             type: "ST",
             suf_direction: "",
             city: "Steilacoom",
             lat: 47.1663769816001,
             lon: -122.60899603847912,
             is_active: true
           }
  end

  test "marks a TEMPORARY point inactive and every ACTIVE point active", %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, layer_features())
    active = Enum.map(records(export), & &1.is_active)

    assert Enum.count(active, & &1) == 6
    assert Enum.count(active, &(not &1)) == 2
  end

  test "keeps a compound type as the county writes it, for the normalizer to read",
       %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, layer_features())
    read = records(export)

    assert Enum.any?(read, &(&1.type == "ST CT" and &1.suf_direction == "E"))
    assert Enum.any?(read, &(&1.type == "AVE PL"))
    assert Enum.any?(read, &(&1.type == "ST LP" and &1.suf_direction == "NE"))
  end

  test "a null prefix directional is empty and a present one is kept", %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, layer_features())
    read = records(export)

    assert Enum.find(read, &(&1.name == "3RD")).pre_direction == ""
    assert Enum.find(read, &(&1.name == "MASON")).pre_direction == "E"
  end

  test "asks the county's FeatureServer host for each page above the last OBJECTID in WGS 84",
       %{tmp_dir: tmp_dir} do
    {:ok, _export} = fetch(tmp_dir, numbered(150))

    assert_received {:request, @layer_path <> "/query", %{"where" => "OBJECTID>0"} = first}
    assert_received {:request, @layer_path <> "/query", %{"where" => "OBJECTID>100"}}
    assert first["outSR"] == "4326"
    assert first["resultRecordCount"] == "100"
    assert first["outFields"] =~ "Status"
    assert first["outFields"] =~ "HouseNumber"
  end

  test "reads from services2.arcgis.com alone, a host that publishes an IPv6 address",
       %{tmp_dir: tmp_dir} do
    {:ok, _export} = fetch(tmp_dir, numbered(150))

    hosts = collect_hosts([])
    assert hosts != []
    assert Enum.uniq(hosts) == ["services2.arcgis.com"]
  end

  defp collect_hosts(hosts) do
    receive do
      {:host, host} -> collect_hosts([host | hosts])
    after
      0 -> hosts
    end
  end

  test "a layer whose count moves while it is read is an error", %{tmp_dir: tmp_dir} do
    script = fn conn ->
      case conn.query_params do
        %{"returnCountOnly" => "true"} -> {200, ~s({"count":151})}
        _other -> :default
      end
    end

    assert fetch(tmp_dir, numbered(150), script: script) ==
             {:error, {:record_count_differs, 150, 151}}
  end

  test "a page that fails for good is an error", %{tmp_dir: tmp_dir} do
    script = fn conn ->
      case conn.query_params do
        %{"where" => "OBJECTID>100"} -> {404, ""}
        _other -> :default
      end
    end

    assert fetch(tmp_dir, numbered(150), script: script) == {:error, {:unexpected_status, 404}}
  end

  describe "records/1" do
    test "a status other than ACTIVE, an empty one included, is inactive", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "pierce.csv")

      File.write!(
        path,
        @header <> "5,,MAIN,ST,,Tacoma,active,-122.4,47.2\n6,,MAIN,ST,,Tacoma,,-122.4,47.2\n"
      )

      assert [%{is_active: false}, %{is_active: false}] =
               path |> Pierce.records() |> Enum.to_list()
    end

    test "a position that is no number is nil", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "pierce.csv")
      File.write!(path, @header <> "5,,MAIN,ST,,Tacoma,ACTIVE,,x\n")

      assert [%{lat: nil, lon: nil}] = path |> Pierce.records() |> Enum.to_list()
    end

    test "a file with a column missing is an assertion failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "pierce.csv")
      File.write!(path, "HouseNumber\n5\n")

      assert_raise Gobusgo.Assert.AssertionError, ~r/the file has no \w+ column/, fn ->
        path |> Pierce.records() |> Enum.to_list()
      end
    end
  end
end
