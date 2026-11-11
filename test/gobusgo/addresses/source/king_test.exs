defmodule Gobusgo.Addresses.Source.KingTest do
  # Drives fetch/1 against a plug that answers as the county's FeatureServer
  # answers: the layer, its record count, and two pages recorded from the
  # layer on 2026-11-11, and reads the records of the pages. No request
  # leaves the machine.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Gobusgo.Addresses.Source.King

  @pages Path.expand("../../../fixtures/addresses/king_pages", __DIR__)
  @layer_path "/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @layer_last_edit_ms 1_794_228_994_534
  @layer_count 199

  defp plug(overrides) do
    answers = Map.merge(default_answers(), overrides)

    fn conn ->
      conn = fetch_query_params(conn)
      query_path = @layer_path <> "/query"

      case {conn.request_path, conn.query_params} do
        {@layer_path, _query} -> answers.layer.(conn)
        {^query_path, %{"returnCountOnly" => "true"}} -> answers.count.(conn)
        {^query_path, %{"resultOffset" => offset}} -> answers.page.(conn, offset)
      end
    end
  end

  defp default_answers do
    %{
      layer: fn conn ->
        body = JSON.encode!(%{"editingInfo" => %{"lastEditDate" => @layer_last_edit_ms}})
        send_resp(conn, 200, body)
      end,
      count: fn conn -> send_resp(conn, 200, JSON.encode!(%{"count" => @layer_count})) end,
      page: fn conn, offset ->
        name = %{"0" => "offset_0.json", "100" => "offset_675300.json"} |> Map.fetch!(offset)
        send_resp(conn, 200, File.read!(Path.join(@pages, name)))
      end
    }
  end

  defp fetch(overrides \\ %{}) do
    King.fetch(plug: plug(overrides), request_interval_ms: 0, retry_base_ms: 0)
  end

  defp records do
    {:ok, layer} = fetch()

    for {:records, records, _request_count} <- Enum.to_list(layer.pages),
        record <- records,
        do: record
  end

  test "reports the layer's last edit and record count" do
    assert {:ok, layer} = fetch()
    assert layer.last_edit_at == ~U[2026-11-09 12:56:34.534Z]
    assert layer.record_count == @layer_count
  end

  test "reads each feature of the pages as a record of the fields the build uses" do
    records = records()

    assert length(records) == @layer_count

    assert hd(records) == %{
             house_number: "14243",
             pre_direction: "SW",
             name: "LISABEULA",
             type: "RD",
             suf_direction: "",
             city: "VASHON",
             lat: 47.40517878141594,
             lon: -122.51961713056957
           }
  end

  test "keeps a house number's letter as the county writes it" do
    assert "4138 A" in Enum.map(records(), & &1.house_number)
  end

  test "a layer that answers with an error object is a malformed answer" do
    layer = fn conn -> send_resp(conn, 200, JSON.encode!(%{"error" => %{"code" => 400}})) end
    assert fetch(%{layer: layer}) == {:error, {:malformed, "editingInfo"}}
  end

  test "a page that fails ends the pages with its reason" do
    page = fn conn, _offset -> send_resp(conn, 404, "") end
    {:ok, layer} = fetch(%{page: page})

    assert Enum.to_list(layer.pages) == [{:failed, {:page, 0, {:unexpected_status, 404}}}]
  end
end
