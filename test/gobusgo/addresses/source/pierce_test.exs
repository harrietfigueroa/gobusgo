defmodule Gobusgo.Addresses.Source.PierceTest do
  # Drives fetch/1 against a plug that answers as the county's FeatureServer
  # layer does (its description, its count, and its pages of features whose
  # values are rows of the live layer), and reads the records of the pages.
  # No request leaves the machine.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Source.Pierce
  alias Gobusgo.Test.FeatureLayer

  @layer_path "/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Address_Points/FeatureServer/0"
  @layer_last_edit_ms 1_793_967_773_886

  # Rows of the layer as its query answered them on 2026-11-11: compound
  # types, a LOOP, a prefix directional, TEMPORARY points, and the nulls the
  # service gives for an empty prefix directional.
  @rows [
    {"611", nil, "3RD", "ST", "", "Steilacoom", "ACTIVE", -122.60899603847912, 47.1663769816001},
    {"7218", nil, "45TH", "ST CT", "E", "Fife", "ACTIVE", -122.3318961645315, 47.21532711294391},
    {"406", nil, "25TH", "AVE PL", "", "Milton", "ACTIVE", -122.30087242613375,
     47.254259165664614},
    {"5568", nil, "34TH", "ST LP", "NE", "Tacoma", "ACTIVE", -122.37565363270177,
     47.28817785033674},
    {"2104", nil, "62ND", "LOOP", "SE", "Auburn", "ACTIVE", -122.20274060653425,
     47.25317088995783},
    {"110", nil, "UNION", "AVE", "", "Steilacoom", "TEMPORARY", -122.60336098587082,
     47.17096950275996},
    {"1811", nil, "NISQUALLY", "ST", "", "Steilacoom", "TEMPORARY", -122.59488254433343,
     47.171709165258065},
    {"272", "E", "MASON", "AVE", "", "Buckley", "ACTIVE", -122.03420835386942, 47.16187136375911}
  ]

  defp feature({number, prefix, name, type, suffix, city, status, x, y}) do
    %{
      "attributes" => %{
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

  defp layer_features, do: Enum.map(@rows, &feature/1)

  defp fetch(features, script \\ fn _conn -> :default end) do
    Pierce.fetch(
      plug:
        FeatureLayer.plug(%{
          test_pid: self(),
          path: @layer_path,
          last_edit_ms: @layer_last_edit_ms,
          features: features,
          script: script
        }),
      request_interval_ms: 0,
      retry_base_ms: 0
    )
  end

  defp records(features) do
    {:ok, layer} = fetch(features)

    for {:records, records, _request_count} <- Enum.to_list(layer.pages),
        record <- records,
        do: record
  end

  test "reports the layer's last edit and record count" do
    assert {:ok, layer} = fetch(layer_features())
    assert layer.last_edit_at == ~U[2026-11-06 12:22:53.886Z]
    assert layer.record_count == 8
  end

  test "reads each feature as a record of the fields the build uses, at its WGS 84 point" do
    assert hd(records(layer_features())) == %{
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

  test "reads every record of a layer longer than a page" do
    features = Enum.flat_map(1..30, fn _copy -> layer_features() end)
    assert length(records(features)) == 240
  end

  test "marks a TEMPORARY point inactive and every ACTIVE point active" do
    active = Enum.map(records(layer_features()), & &1.is_active)

    assert Enum.count(active, & &1) == 6
    assert Enum.count(active, &(not &1)) == 2
  end

  test "a status other than ACTIVE, an empty one included, is inactive" do
    lower = put_in(feature(hd(@rows)), ["attributes", "Status"], "active")
    empty = put_in(feature(hd(@rows)), ["attributes", "Status"], nil)

    assert [%{is_active: false}, %{is_active: false}] = records([lower, empty])
  end

  test "keeps a compound type as the county writes it, for the normalizer to read" do
    read = records(layer_features())

    assert Enum.any?(read, &(&1.type == "ST CT" and &1.suf_direction == "E"))
    assert Enum.any?(read, &(&1.type == "AVE PL"))
    assert Enum.any?(read, &(&1.type == "ST LP" and &1.suf_direction == "NE"))
  end

  test "a null prefix directional is empty and a present one is kept" do
    read = records(layer_features())

    assert Enum.find(read, &(&1.name == "3RD")).pre_direction == ""
    assert Enum.find(read, &(&1.name == "MASON")).pre_direction == "E"
  end

  test "a feature with no point has no position" do
    bare = Map.delete(feature(hd(@rows)), "geometry")
    assert [%{lat: nil, lon: nil}] = records([bare])
  end

  test "asks for the fields the build reads, in WGS 84, 100 records a page" do
    records(layer_features())

    assert_received {:request, _host, @layer_path <> "/query", %{"resultOffset" => "0"} = query}
    assert query["outSR"] == "4326"
    assert query["resultRecordCount"] == "100"

    assert query["outFields"] ==
             "City,HouseNumber,PostDirectional,PrefixDirectional,Status,StreetName,StreetType"
  end

  test "reads from services2.arcgis.com alone, a host that publishes an IPv6 address" do
    records(layer_features())

    hosts = collect_hosts([])
    assert hosts != []
    assert Enum.uniq(hosts) == ["services2.arcgis.com"]
  end

  defp collect_hosts(hosts) do
    receive do
      {:request, host, _path, _query} -> collect_hosts([host | hosts])
    after
      0 -> hosts
    end
  end

  test "a page that fails ends the pages with its reason" do
    script = fn conn ->
      case conn.query_params do
        %{"resultOffset" => _offset} -> {404, ""}
        _other -> :default
      end
    end

    {:ok, layer} = fetch(layer_features(), script)

    assert Enum.to_list(layer.pages) == [{:failed, {:page, 0, {:unexpected_status, 404}}}]
  end
end
