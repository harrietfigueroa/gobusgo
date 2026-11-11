defmodule Gobusgo.Addresses.Source.PierceTest do
  # Drives fetch/2 against a plug that answers as the three services the
  # source reads answer (the FeatureServer, the Hub's download API, and the
  # file's blob store), and reads the records of the sample cut from the
  # county's real WGS 84 export. No request leaves the machine.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Gobusgo.Addresses.Source.Pierce

  @moduletag :tmp_dir

  @sample Path.expand("../../../fixtures/addresses/pierce_sample.csv", __DIR__)
  @layer_path "/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Address_Points/FeatureServer/0"
  @layer_last_edit_ms 1_793_967_773_886
  @layer_count 11

  defp answer(conn, status, body, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)

    send_resp(conn, status, body)
  end

  defp plug(test_pid, overrides) do
    answers = Map.merge(default_answers(), overrides)

    fn conn ->
      conn = fetch_query_params(conn)
      send(test_pid, {:request, conn.host, conn.request_path, conn.query_params})

      case {conn.host, conn.request_path} do
        {"hub.arcgis.com", _path} -> answers.hub.(conn)
        {"services2.arcgis.com", @layer_path} -> answers.layer.(conn)
        {"services2.arcgis.com", @layer_path <> "/query"} -> answers.count.(conn)
        {"services2.arcgis.com", _result} -> answers.result.(conn)
        {"stg-arcgisazurecdataprod2.az.arcgis.com", _blob} -> answers.blob.(conn)
      end
    end
  end

  defp default_answers do
    %{
      layer: fn conn ->
        answer(
          conn,
          200,
          JSON.encode!(%{"editingInfo" => %{"lastEditDate" => @layer_last_edit_ms}})
        )
      end,
      count: fn conn -> answer(conn, 200, JSON.encode!(%{"count" => @layer_count})) end,
      hub: fn conn ->
        body = %{
          "status" => "Completed",
          "resultUrl" => "https://services2.arcgis.com/1UvBaQ5y1ubjUPmd/export/pierce.csv"
        }

        answer(conn, 200, JSON.encode!(body))
      end,
      result: fn conn ->
        answer(conn, 302, "<html></html>", [
          {"location",
           "https://stg-arcgisazurecdataprod2.az.arcgis.com/exportfiles/pierce.csv?sig=SECRET"}
        ])
      end,
      blob: fn conn ->
        answer(conn, 200, File.read!(@sample), [
          {"x-ms-meta-lasteditdate", Integer.to_string(@layer_last_edit_ms)},
          {"x-ms-meta-recordcount", Integer.to_string(@layer_count)}
        ])
      end
    }
  end

  defp fetch(tmp_dir, overrides \\ %{}) do
    Pierce.fetch(%{directory: tmp_dir, bytes_max: 1_000_000},
      plug: plug(self(), overrides),
      poll_delay_ms: 0
    )
  end

  test "downloads a current export and reports the layer's last edit and count", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, export} = fetch(tmp_dir)

    assert export.last_edit_at == ~U[2026-11-06 12:22:53.886Z]
    assert export.record_count == @layer_count
    assert File.read!(export.path) == File.read!(@sample)
  end

  test "asks the Hub for the export in WGS 84, so the server needs no projection", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _export} = fetch(tmp_dir)

    assert_received {:request, "hub.arcgis.com", "/api/download/v1/items/" <> item, query}
    assert item == "c8361c8247da4430922e4439da8513c8/csv"
    assert query["spatialRefId"] == "4326"
    assert query["layers"] == "0"
  end

  test "an export older than the layer is stale", %{tmp_dir: tmp_dir} do
    blob = fn conn ->
      answer(conn, 200, File.read!(@sample), [
        {"x-ms-meta-lasteditdate", Integer.to_string(@layer_last_edit_ms - 1)},
        {"x-ms-meta-recordcount", Integer.to_string(@layer_count)}
      ])
    end

    assert {:stale, %{reason: :export_older_than_layer}} = fetch(tmp_dir, %{blob: blob})
  end

  test "an export with another record count is stale", %{tmp_dir: tmp_dir} do
    blob = fn conn ->
      answer(conn, 200, File.read!(@sample), [
        {"x-ms-meta-lasteditdate", Integer.to_string(@layer_last_edit_ms)},
        {"x-ms-meta-recordcount", Integer.to_string(@layer_count + 1)}
      ])
    end

    assert {:stale, %{reason: :record_count_differs, layer_record_count: @layer_count}} =
             fetch(tmp_dir, %{blob: blob})
  end

  describe "records/1" do
    test "reads every row, the first with the fields the build uses and WGS 84 degrees" do
      records = @sample |> Pierce.records() |> Enum.to_list()

      assert length(records) == @layer_count

      assert hd(records) == %{
               house_number: "611",
               pre_direction: "",
               name: "3RD",
               type: "ST",
               suf_direction: "",
               city: "Steilacoom",
               lat: 47.16638260496189,
               lon: -122.60901080998788,
               is_active: true
             }
    end

    test "marks a TEMPORARY point inactive and every ACTIVE point active" do
      active = @sample |> Pierce.records() |> Enum.map(& &1.is_active)
      assert Enum.count(active, & &1) == 9
      assert Enum.count(active, &(not &1)) == 2
    end

    test "keeps a compound type as the county writes it, for the normalizer to read" do
      records = @sample |> Pierce.records() |> Enum.to_list()
      assert Enum.any?(records, &(&1.type == "ST CT" and &1.suf_direction == "E"))
      assert Enum.any?(records, &(&1.type == "AVE PL"))
      assert Enum.any?(records, &(&1.type == "ST LP" and &1.suf_direction == "NE"))
    end

    test "a status other than ACTIVE, an empty one included, is inactive", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "export.csv")

      File.write!(
        path,
        "OBJECTID,HouseNumber,PrefixDirectional,StreetName,StreetType,PostDirectional,City,Status,x,y\n" <>
          "1,5,,MAIN,ST,,Tacoma,active,-122.4,47.2\n2,6,,MAIN,ST,,Tacoma,,-122.4,47.2\n"
      )

      assert [%{is_active: false}, %{is_active: false}] =
               path |> Pierce.records() |> Enum.to_list()
    end

    test "a position that is no number is nil", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "export.csv")

      File.write!(
        path,
        "OBJECTID,HouseNumber,PrefixDirectional,StreetName,StreetType,PostDirectional,City,Status,x,y\n" <>
          "1,5,,MAIN,ST,,Tacoma,ACTIVE,,x\n"
      )

      assert [%{lat: nil, lon: nil}] = path |> Pierce.records() |> Enum.to_list()
    end

    test "an export with a column missing is an assertion failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "export.csv")
      File.write!(path, "OBJECTID,HouseNumber\n1,5\n")

      assert_raise Gobusgo.Assert.AssertionError, ~r/the export has no \w+ column/, fn ->
        path |> Pierce.records() |> Enum.to_list()
      end
    end
  end
end
