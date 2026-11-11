defmodule Gobusgo.Addresses.Source.SnohomishTest do
  # Drives fetch/1 against a plug that answers as the county's FeatureServer
  # layer does (its description, its count, and its pages), and reads the
  # records of the pages. No request leaves the machine.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Source.Snohomish
  alias Gobusgo.Test.FeatureLayer

  @layer_path "/z6WYi9VRHfgwgtyW/arcgis/rest/services/Building_Address_Points/FeatureServer/0"
  @layer_last_edit_ms 1_794_308_862_375

  defp feature(index, overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          "Add_Number" => "#{index * 10}",
          "AddNum_Suf" => "",
          "LSt_PreDir" => "",
          "LSt_Name" => "119TH",
          "LSt_Type" => "DR",
          "LSt_PostDir" => "SE",
          "Post_Comm" => "LAKE STEVENS"
        },
        overrides
      )

    %{"attributes" => attributes, "geometry" => %{"x" => -122.07 + index / 1.0e5, "y" => 47.99}}
  end

  defp fetch(features, script \\ fn _conn -> :default end) do
    Snohomish.fetch(
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
    assert {:ok, layer} = fetch(Enum.map(1..250, &feature/1))
    assert layer.last_edit_at == ~U[2026-11-10 11:07:42.375Z]
    assert layer.record_count == 250
  end

  test "reads every record of a layer longer than a page" do
    assert length(records(Enum.map(1..250, &feature/1))) == 250
  end

  test "reads each feature as a record of the fields the build uses" do
    assert records([feature(7, %{"AddNum_Suf" => "B"})]) == [
             %{
               house_number: "70 B",
               pre_direction: "",
               name: "119TH",
               type: "DR",
               suf_direction: "SE",
               city: "LAKE STEVENS",
               lat: 47.99,
               lon: -122.07 + 7 / 1.0e5
             }
           ]
  end

  test "a feature with no point has no position" do
    bare = Map.delete(feature(3), "geometry")
    assert [%{lat: nil, lon: nil}] = records([bare])
  end

  test "an attribute that is null is read as empty text" do
    assert [%{pre_direction: "", house_number: "30"}] =
             records([feature(3, %{"LSt_PreDir" => nil, "AddNum_Suf" => nil})])
  end

  test "asks for the short spelling of the street in WGS 84, 100 records a page" do
    records([feature(1)])

    assert_received {:request, _host, @layer_path <> "/query", %{"resultOffset" => "0"} = query}
    assert query["outSR"] == "4326"
    assert query["resultRecordCount"] == "100"

    assert query["outFields"] ==
             "AddNum_Suf,Add_Number,LSt_Name,LSt_PostDir,LSt_PreDir,LSt_Type,Post_Comm"
  end

  test "reads from services6.arcgis.com alone, a host that publishes an IPv6 address" do
    records([feature(1)])

    hosts = collect_hosts([])
    assert hosts != []
    assert Enum.uniq(hosts) == ["services6.arcgis.com"]
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
        %{"resultOffset" => "100"} -> {404, ""}
        _other -> :default
      end
    end

    {:ok, layer} = fetch(Enum.map(1..150, &feature/1), script)

    assert [{:records, _records, 1}, {:failed, {:page, 100, {:unexpected_status, 404}}}] =
             Enum.to_list(layer.pages)
  end

  test "a layer with no last edit is a malformed answer" do
    script = fn
      %{request_path: @layer_path} -> {200, ~s({"error":{"code":400}})}
      _conn -> :default
    end

    assert fetch([feature(1)], script) == {:error, {:malformed, "editingInfo"}}
  end
end
