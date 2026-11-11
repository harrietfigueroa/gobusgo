defmodule Gobusgo.Addresses.Source.KingTest do
  # Drives fetch/2 against a plug that answers as the three services the
  # source reads answer (the FeatureServer, the Hub's download API, and the
  # file's blob store), with variations a test sets, and reads the
  # records of the sample cut from the county's real export. No request
  # leaves the machine.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Gobusgo.Addresses.Source.King

  @moduletag :tmp_dir

  @sample Path.expand("../../../fixtures/addresses/king_sample.csv", __DIR__)
  @layer_last_edit_ms 1_794_228_994_534
  @layer_count 15

  defp answer(conn, status, body, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)

    send_resp(conn, status, body)
  end

  # The plug of a service whose answers a test overrides by name.
  defp plug(overrides) do
    answers = Map.merge(default_answers(), overrides)

    fn conn ->
      conn = fetch_query_params(conn)

      case {conn.host, conn.request_path} do
        {"hub.arcgis.com", _path} ->
          answers.hub.(conn)

        {"services.arcgis.com",
         "/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"} ->
          answers.layer.(conn)

        {"services.arcgis.com",
         "/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0/query"} ->
          answers.count.(conn)

        {"services.arcgis.com", _result} ->
          answers.result.(conn)

        {"stg-arcgisazurecdataprod.az.arcgis.com", _blob} ->
          answers.blob.(conn)
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
          "resultUrl" => "https://services.arcgis.com/Ej0PsM5Aw677QF1W/export/king.csv"
        }

        answer(conn, 200, JSON.encode!(body))
      end,
      result: fn conn ->
        answer(conn, 302, "<html></html>", [
          {"location",
           "https://stg-arcgisazurecdataprod.az.arcgis.com/exportfiles/king.csv?sig=SECRET"}
        ])
      end,
      blob: fn conn ->
        answer(conn, 200, File.read!(@sample), export_headers(@layer_last_edit_ms, @layer_count))
      end
    }
  end

  defp export_headers(last_edit_ms, count) do
    [
      {"x-ms-meta-lasteditdate", Integer.to_string(last_edit_ms)},
      {"x-ms-meta-recordcount", Integer.to_string(count)}
    ]
  end

  defp fetch(tmp_dir, overrides \\ %{}, bytes_max \\ 1_000_000) do
    King.fetch(%{directory: tmp_dir, bytes_max: bytes_max},
      plug: plug(overrides),
      poll_delay_ms: 0
    )
  end

  test "downloads a current export and reports the layer's last edit and count", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, export} = fetch(tmp_dir)

    assert export.last_edit_at == ~U[2026-11-09 12:56:34.534Z]
    assert export.record_count == @layer_count
    assert export.byte_count == File.stat!(@sample).size
    assert File.read!(export.path) == File.read!(@sample)
  end

  test "an export with a later edit than the layer's is current", %{tmp_dir: tmp_dir} do
    blob = fn conn ->
      answer(
        conn,
        200,
        File.read!(@sample),
        export_headers(@layer_last_edit_ms + 1, @layer_count)
      )
    end

    assert {:ok, _export} = fetch(tmp_dir, %{blob: blob})
  end

  for {name, last_edit_ms, count, reason} <- [
        {"an export older than the layer", @layer_last_edit_ms - 1, @layer_count,
         :export_older_than_layer},
        {"an export with another record count", @layer_last_edit_ms, @layer_count - 1,
         :record_count_differs}
      ] do
    test "#{name} is stale and none of its body is written", %{tmp_dir: tmp_dir} do
      blob = fn conn ->
        answer(
          conn,
          200,
          File.read!(@sample),
          export_headers(unquote(last_edit_ms), unquote(count))
        )
      end

      assert {:stale, stale} = fetch(tmp_dir, %{blob: blob})
      assert stale.reason == unquote(reason)
      assert stale.layer_record_count == @layer_count
      assert File.stat!(Path.join(tmp_dir, "king-addresses.csv")).size == 0
    end
  end

  test "an export that carries no metadata is stale", %{tmp_dir: tmp_dir} do
    blob = fn conn -> answer(conn, 200, File.read!(@sample)) end
    assert {:stale, %{reason: :export_metadata_missing}} = fetch(tmp_dir, %{blob: blob})
  end

  test "an export still being made is asked for again", %{tmp_dir: tmp_dir} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    hub = fn conn ->
      polls = Agent.get_and_update(counter, &{&1, &1 + 1})

      if polls < 2 do
        answer(conn, 200, JSON.encode!(%{"status" => "InProgress"}))
      else
        default_answers().hub.(conn)
      end
    end

    assert {:ok, _export} = fetch(tmp_dir, %{hub: hub})
    assert Agent.get(counter, & &1) == 3
  end

  test "an export that never finishes is an error after the polls are spent", %{tmp_dir: tmp_dir} do
    hub = fn conn -> answer(conn, 200, JSON.encode!(%{"status" => "Pending"})) end
    assert fetch(tmp_dir, %{hub: hub}) == {:error, :export_not_ready}
  end

  for {name, status, body, expected} <- [
        {"a failed export", 200, ~s({"status":"Failed"}), {:error, :export_failed}},
        {"an item that cannot be downloaded", 400,
         ~s({"message":"Downloads are not supported for this item."}),
         {:error, :export_not_supported}},
        {"a layer the item lacks", 404, ~s({"message":"Layer does not exist."}),
         {:error, :export_not_found}},
        {"an undocumented status", 503, "", {:error, {:unexpected_status, 503}}},
        {"a body that is no export status", 200, ~s({"unrelated":true}),
         {:error, {:malformed, "status"}}}
      ] do
    test "#{name} is a value", %{tmp_dir: tmp_dir} do
      hub = fn conn -> answer(conn, unquote(status), unquote(body)) end
      assert fetch(tmp_dir, %{hub: hub}) == unquote(Macro.escape(expected))
    end
  end

  test "a redirect to a host outside arcgis.com is refused", %{tmp_dir: tmp_dir} do
    result = fn conn -> answer(conn, 302, "", [{"location", "https://example.com/king.csv"}]) end
    assert fetch(tmp_dir, %{result: result}) == {:error, :address_refused}
  end

  test "a redirect over plain http is refused", %{tmp_dir: tmp_dir} do
    result = fn conn ->
      answer(conn, 302, "", [
        {"location", "http://stg-arcgisazurecdataprod.az.arcgis.com/king.csv"}
      ])
    end

    assert fetch(tmp_dir, %{result: result}) == {:error, :address_refused}
  end

  test "an endless chain of redirects ends", %{tmp_dir: tmp_dir} do
    blob = fn conn ->
      answer(conn, 302, "", [{"location", "https://stg-arcgisazurecdataprod.az.arcgis.com/again"}])
    end

    assert fetch(tmp_dir, %{blob: blob}) == {:error, :too_many_redirects}
  end

  test "an export past the byte bound is an error", %{tmp_dir: tmp_dir} do
    assert fetch(tmp_dir, %{}, 100) == {:error, :body_too_large}
  end

  test "a layer that answers with an error object is a malformed answer", %{tmp_dir: tmp_dir} do
    layer = fn conn -> answer(conn, 200, JSON.encode!(%{"error" => %{"code" => 400}})) end
    assert fetch(tmp_dir, %{layer: layer}) == {:error, {:malformed, "editingInfo"}}
  end

  test "a status the blob store does not document is an error", %{tmp_dir: tmp_dir} do
    blob = fn conn -> answer(conn, 403, "") end
    assert fetch(tmp_dir, %{blob: blob}) == {:error, {:unexpected_status, 403}}
  end

  describe "records/1" do
    test "reads each row of the export as a record of the fields the build uses" do
      records = @sample |> King.records() |> Enum.to_list()

      assert length(records) == @layer_count

      assert hd(records) == %{
               house_number: "14243",
               pre_direction: "SW",
               name: "LISABEULA",
               type: "RD",
               suf_direction: "",
               city: "VASHON",
               lat: 47.40517878,
               lon: -122.51961713
             }
    end

    test "keeps a house number's letter and a fraction as the county writes them" do
      numbers = @sample |> King.records() |> Enum.map(& &1.house_number)
      assert "4138 A" in numbers
      assert "17657 1/2" in numbers
    end

    test "reads a row whose comment holds line breaks as one record" do
      cities = @sample |> King.records() |> Enum.map(& &1.city)
      assert "FEDERAL WAY" in cities
    end

    test "a position that is no number is nil", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "export.csv")

      File.write!(
        path,
        "HouseNum,PreDir,StreetName,SufType,SufDir,POSTALCTYNAME,LAT,LON\n1,,MAIN,ST,,KENT,,x\n"
      )

      assert [%{lat: nil, lon: nil}] = path |> King.records() |> Enum.to_list()
    end

    test "an export without a column the build reads fails an assertion", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "export.csv")
      File.write!(path, "HouseNum,StreetName\n1,MAIN\n")

      assert_raise Gobusgo.Assert.AssertionError, fn ->
        path |> King.records() |> Enum.to_list()
      end
    end
  end
end
