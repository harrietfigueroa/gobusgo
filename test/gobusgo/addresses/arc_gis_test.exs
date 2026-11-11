defmodule Gobusgo.Addresses.ArcGisTest do
  # Drives pages/2 against a plug that answers a layer of 199 records with
  # two pages recorded from King County's layer on 2026-11-11, a full first
  # page and the layer's short last page, and with failures a test sets per
  # request. The offsets asked for, the pages read, and the requests each
  # took are read from the stream and from what the plug received. No
  # request leaves the machine.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Gobusgo.Addresses.ArcGis

  @pages Path.expand("../../fixtures/addresses/king_pages", __DIR__)
  @layer_url "https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @out_fields ["ADDR_HN", "ADDR_PD", "ADDR_SN", "ADDR_ST", "ADDR_SD", "POSTALCTYNAME"]
  @record_count 199

  defp recorded(offset) do
    name =
      case offset do
        "0" -> "offset_0.json"
        "100" -> "offset_675300.json"
      end

    File.read!(Path.join(@pages, name))
  end

  # A plug that answers each request with `answer.(offset, attempt)`, a
  # `{status, body}` or `{status, body, headers}`, and keeps every offset it
  # was asked for in the agent.
  defp plug(agent, answer) do
    fn conn ->
      conn = fetch_query_params(conn)
      offset = conn.query_params["resultOffset"]

      attempt =
        Agent.get_and_update(agent, fn requests ->
          {Enum.count(requests, &(&1["resultOffset"] == offset)), [conn.query_params | requests]}
        end)

      case answer.(offset, attempt) do
        {status, body} -> send_resp(conn, status, body)
        {status, body, headers} -> conn |> merge_resp_headers(headers) |> send_resp(status, body)
      end
    end
  end

  defp recorded_answer(offset, _attempt), do: {200, recorded(offset)}

  defp pages(answer) do
    {:ok, agent} = Agent.start_link(fn -> [] end, [])

    {:ok, stream} =
      ArcGis.pages(%{layer_url: @layer_url, out_fields: @out_fields, record_count: @record_count},
        plug: plug(agent, answer),
        request_interval_ms: 0,
        retry_base_ms: 0
      )

    items = Enum.to_list(stream)
    requests = Agent.get(agent, & &1)
    %{items: items, requests: Enum.reverse(requests)}
  end

  test "asks for each page once, at the offsets of 100 records apart" do
    %{requests: requests} = pages(&recorded_answer/2)

    assert requests |> Enum.map(& &1["resultOffset"]) |> Enum.sort() == ["0", "100"]
    assert Enum.all?(requests, &(&1["resultRecordCount"] == "100"))
    assert Enum.all?(requests, &(&1["orderByFields"] == "OBJECTID"))
    assert Enum.all?(requests, &(&1["outSR"] == "4326"))
  end

  test "hands over the pages in offset order, the last one short" do
    %{items: items} = pages(&recorded_answer/2)

    assert [{:features, first, 1}, {:features, last, 1}] = items
    assert length(first) == 100
    assert length(last) == 99
    assert hd(first).attributes["ADDR_SN"] == "LISABEULA"
    assert hd(last).attributes["ADDR_SN"] == "SPEAR"
  end

  for {name, failure} <- [
        {"a 503", {503, ""}},
        {"a 429 with a Retry-After", {429, "", [{"retry-after", "0"}]}},
        {"an error object with a 500 code", {200, ~s({"error":{"code":500,"message":"x"}})}}
      ] do
    test "#{name} is asked for again and the page counts both requests" do
      answer = fn
        "100", 0 -> unquote(Macro.escape(failure))
        offset, attempt -> recorded_answer(offset, attempt)
      end

      %{items: items} = pages(answer)
      assert [{:features, _first, 1}, {:features, last, 2}] = items
      assert length(last) == 99
    end
  end

  test "a transient failure that does not clear ends the stream after the attempts" do
    answer = fn
      "0", _attempt -> {503, ""}
      offset, attempt -> recorded_answer(offset, attempt)
    end

    %{items: items, requests: requests} = pages(answer)

    assert [{:failed, {:page, 0, {:unexpected_status, 503}}}] = items
    assert Enum.count(requests, &(&1["resultOffset"] == "0")) == ArcGis.attempt_count_max()
  end

  test "a failure that is not transient ends the stream after one request" do
    error = ~s({"error":{"code":400,"message":"Cannot perform query. Invalid query parameters."}})

    answer = fn
      "100", _attempt -> {200, error}
      offset, attempt -> recorded_answer(offset, attempt)
    end

    %{items: items, requests: requests} = pages(answer)

    assert [{:features, _first, 1}, {:failed, {:page, 100, {:service_error, 400}}}] = items
    assert Enum.count(requests, &(&1["resultOffset"] == "100")) == 1
  end

  test "an undocumented status ends the stream after one request" do
    answer = fn
      "0", _attempt -> {403, ""}
      offset, attempt -> recorded_answer(offset, attempt)
    end

    assert %{items: [{:failed, {:page, 0, {:unexpected_status, 403}}}]} = pages(answer)
  end

  test "a record count past the bound on pages is refused before any request" do
    count = Gobusgo.Addresses.FeaturePages.record_count_max() + 1

    assert ArcGis.pages(
             %{layer_url: @layer_url, out_fields: @out_fields, record_count: count},
             []
           ) == {:error, {:record_count_too_large, count}}
  end
end
