defmodule Gobusgo.Addresses.Source.SnohomishTest do
  # Drives fetch/2 against a plug that answers as the county's FeatureServer
  # layer does (its description, its count, and its pages), and reads the
  # records of the file the fetch wrote. No request leaves the machine.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Source.Snohomish
  alias Gobusgo.Test.FeatureLayer

  @moduletag :tmp_dir

  @layer_path "/z6WYi9VRHfgwgtyW/arcgis/rest/services/Building_Address_Points/FeatureServer/0"
  @layer_last_edit_ms 1_794_308_862_375

  defp feature(object_id, overrides \\ %{}) do
    attributes =
      Map.merge(
        %{
          "OBJECTID" => object_id,
          "Add_Number" => "#{object_id * 10}",
          "AddNum_Suf" => "",
          "LSt_PreDir" => "",
          "LSt_Name" => "119TH",
          "LSt_Type" => "DR",
          "LSt_PostDir" => "SE",
          "Post_Comm" => "LAKE STEVENS"
        },
        overrides
      )

    %{
      "attributes" => attributes,
      "geometry" => %{"x" => -122.07 + object_id / 1.0e5, "y" => 47.99}
    }
  end

  defp fetch(tmp_dir, features, options \\ []) do
    script = Keyword.get(options, :script, fn _conn -> :default end)

    Snohomish.fetch(
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

  defp records(export), do: export.path |> Snohomish.records() |> Enum.to_list()

  test "pages the layer into a file and reports the layer's last edit and the count it read",
       %{tmp_dir: tmp_dir} do
    features = Enum.map(1..250, &feature/1)

    assert {:ok, export} = fetch(tmp_dir, features)

    assert export.last_edit_at == ~U[2026-11-10 11:07:42.375Z]
    assert export.record_count == 250
    assert export.byte_count == File.stat!(export.path).size
    assert length(records(export)) == 250
  end

  test "reads each feature as a record of the fields the build uses", %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, [feature(7, %{"AddNum_Suf" => "B"})])

    assert records(export) == [
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

  test "a feature with no geometry has no position", %{tmp_dir: tmp_dir} do
    bare = %{"attributes" => feature(3)["attributes"]}
    {:ok, export} = fetch(tmp_dir, [bare])

    assert [%{lat: nil, lon: nil}] = records(export)
  end

  test "an attribute that is null is read as empty text", %{tmp_dir: tmp_dir} do
    {:ok, export} = fetch(tmp_dir, [feature(3, %{"LSt_PreDir" => nil, "AddNum_Suf" => nil})])

    assert [%{pre_direction: "", house_number: "30"}] = records(export)
  end

  test "a field with a comma, a quote, or a line break is read back as the county wrote it",
       %{tmp_dir: tmp_dir} do
    city = "LAKE, \"STEVENS\"\nWA"
    {:ok, export} = fetch(tmp_dir, [feature(3, %{"Post_Comm" => city})])

    assert [%{city: ^city}] = records(export)
  end

  test "an empty layer is an export of no records", %{tmp_dir: tmp_dir} do
    assert {:ok, %{record_count: 0} = export} = fetch(tmp_dir, [])
    assert records(export) == []
  end

  test "asks for each page above the last OBJECTID in WGS 84", %{tmp_dir: tmp_dir} do
    {:ok, _export} = fetch(tmp_dir, Enum.map(1..150, &feature/1))

    assert_received {:request, @layer_path <> "/query", %{"returnCountOnly" => "true"}}
    assert_received {:request, @layer_path <> "/query", %{"where" => "OBJECTID>0"} = first}
    assert_received {:request, @layer_path <> "/query", %{"where" => "OBJECTID>100"}}
    assert first["outSR"] == "4326"
    assert first["resultRecordCount"] == "100"
    assert first["outFields"] =~ "LSt_Name"
  end

  test "a page that fails for good is an error and leaves no export", %{tmp_dir: tmp_dir} do
    script = fn conn ->
      case conn.query_params do
        %{"where" => "OBJECTID>100"} -> {404, ""}
        _other -> :default
      end
    end

    assert fetch(tmp_dir, Enum.map(1..150, &feature/1), script: script) ==
             {:error, {:unexpected_status, 404}}
  end

  test "a layer whose count moves while it is read is an error", %{tmp_dir: tmp_dir} do
    script = fn conn ->
      case conn.query_params do
        %{"returnCountOnly" => "true"} -> {200, ~s({"count":151})}
        _other -> :default
      end
    end

    assert fetch(tmp_dir, Enum.map(1..150, &feature/1), script: script) ==
             {:error, {:record_count_differs, 150, 151}}
  end

  test "a layer past the byte bound is an error", %{tmp_dir: tmp_dir} do
    assert fetch(tmp_dir, Enum.map(1..150, &feature/1), bytes_max: 1_000) ==
             {:error, :body_too_large}
  end

  test "a layer with no last edit is a malformed answer", %{tmp_dir: tmp_dir} do
    script = fn
      %{request_path: @layer_path} -> {200, ~s({"error":{"code":400}})}
      _conn -> :default
    end

    assert fetch(tmp_dir, [feature(1)], script: script) == {:error, {:malformed, "editingInfo"}}
  end
end
