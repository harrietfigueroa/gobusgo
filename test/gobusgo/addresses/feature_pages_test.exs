defmodule Gobusgo.Addresses.FeaturePagesTest do
  # Drives stream/2 against a plug that answers as an ArcGIS FeatureServer
  # layer's query endpoint over a table of feature rows, and reads what the
  # query asked for from the requests the plug receives. No request leaves
  # the machine.
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Gobusgo.Addresses.FeaturePages

  @layer_url "https://services6.arcgis.com/test/arcgis/rest/services/Layer/FeatureServer/0"

  defp feature(object_id) do
    %{
      "attributes" => %{"OBJECTID" => object_id, "Name" => "N#{object_id}"},
      "geometry" => %{"x" => -122.0, "y" => 47.0}
    }
  end

  # A layer of `object_ids`, which answers each query as ArcGIS does: the
  # first `resultRecordCount` rows above the `OBJECTID` the `where` names,
  # with `exceededTransferLimit` while more rows remain. `script`, when
  # given, is called with the request number first and may answer in its place.
  defp plug(%{object_ids: object_ids, requests: requests} = layer) do
    fn conn ->
      conn = fetch_query_params(conn)
      number = Agent.get_and_update(requests, &{&1 + 1, &1 + 1})
      Agent.update(layer.log, &(&1 ++ [conn.query_params]))

      case Map.get(layer, :script, fn _number, _conn -> :default end).(number, conn) do
        :default ->
          "OBJECTID>" <> last = conn.query_params["where"]
          size = String.to_integer(conn.query_params["resultRecordCount"])
          above = Enum.filter(object_ids, &(&1 > String.to_integer(last)))
          page = Enum.take(above, size)

          body = %{"features" => Enum.map(page, &feature/1)}

          body =
            if length(above) > size, do: Map.put(body, "exceededTransferLimit", true), else: body

          send_resp(conn, 200, JSON.encode!(body))

        {status, body, headers} ->
          conn =
            Enum.reduce(headers, conn, fn {name, value}, conn ->
              put_resp_header(conn, name, value)
            end)

          send_resp(conn, status, body)
      end
    end
  end

  defp start_layer(object_ids, extra \\ %{}) do
    {:ok, requests} = Agent.start_link(fn -> 0 end)
    {:ok, log} = Agent.start_link(fn -> [] end)
    layer = Map.merge(%{object_ids: object_ids, requests: requests, log: log}, extra)
    %{plug: plug(layer), requests: requests, log: log}
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        url: @layer_url <> "/query",
        out_fields: ["OBJECTID", "Name"],
        page_count_max: 50
      },
      overrides
    )
  end

  defp collect(layer, request \\ request(), options \\ []) do
    options = Keyword.merge([plug: layer.plug, retry_base_ms: 0], options)
    request |> FeaturePages.stream(options) |> Enum.to_list()
  end

  defp object_ids(events) do
    for {:page, features} <- events, feature <- features, do: feature["attributes"]["OBJECTID"]
  end

  test "reads a layer in pages of 100 by the last OBJECTID, in order" do
    layer = start_layer(Enum.to_list(1..250))
    events = collect(layer)

    assert object_ids(events) == Enum.to_list(1..250)
    assert Enum.map(events, fn {:page, features} -> length(features) end) == [100, 100, 50]

    queries = Agent.get(layer.log, & &1)
    assert Enum.map(queries, & &1["where"]) == ["OBJECTID>0", "OBJECTID>100", "OBJECTID>200"]

    for query <- queries do
      assert query["resultRecordCount"] == "100"
      assert query["outSR"] == "4326"
      assert query["orderByFields"] == "OBJECTID"
      assert query["returnGeometry"] == "true"
      assert query["outFields"] == "OBJECTID,Name"
      assert query["f"] == "json"
    end
  end

  test "pages over OBJECTIDs with gaps by the last one seen" do
    layer = start_layer([5, 900, 901, 5000])
    assert layer |> collect() |> object_ids() == [5, 900, 901, 5000]
  end

  test "a layer of a whole number of pages ends on the empty page after it" do
    layer = start_layer(Enum.to_list(1..200))
    events = collect(layer)

    assert object_ids(events) == Enum.to_list(1..200)
    assert Agent.get(layer.requests, & &1) == 3
  end

  test "an empty layer has no page" do
    layer = start_layer([])
    assert collect(layer) == []
  end

  test "is lazy: no request is made until the stream is read" do
    layer = start_layer(Enum.to_list(1..250))
    stream = FeaturePages.stream(request(), plug: layer.plug, retry_base_ms: 0)

    assert Agent.get(layer.requests, & &1) == 0
    assert [{:page, _features}] = Enum.take(stream, 1)
    assert Agent.get(layer.requests, & &1) == 1
  end

  test "a layer with more pages than the bound is an error after the last page it may read" do
    layer = start_layer(Enum.to_list(1..1_000))
    events = collect(layer, request(%{page_count_max: 3}))

    assert length(object_ids(events)) == 300
    assert List.last(events) == {:error, :page_count_exceeded}
  end

  describe "transient failures" do
    for {name, answer} <- [
          {"a 503", {503, "", []}},
          {"a 429", {429, "", []}},
          {"a 408", {408, "", []}},
          {"an error object with a 503 code", {200, ~s({"error":{"code":503}}), []}}
        ] do
      test "#{name} is retried and the page follows" do
        answer = unquote(Macro.escape(answer))

        script = fn
          1, _conn -> answer
          _number, _conn -> :default
        end

        layer = start_layer([1, 2], %{script: script})

        assert layer |> collect() |> object_ids() == [1, 2]
        assert Agent.get(layer.requests, & &1) == 2
      end
    end

    test "honors a Retry-After header in place of the computed delay" do
      script = fn
        1, _conn -> {429, "", [{"retry-after", "0"}]}
        _number, _conn -> :default
      end

      layer = start_layer([1], %{script: script})

      assert layer |> collect(request(), retry_base_ms: 60_000) |> object_ids() == [1]
    end

    test "gives up after three attempts at one page and says so" do
      layer = start_layer([1], %{script: fn _number, _conn -> {503, "", []} end})

      assert collect(layer) == [{:error, {:unexpected_status, 503}}]
      assert Agent.get(layer.requests, & &1) == 3
    end

    test "a transport fault is retried" do
      layer = start_layer([1])
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      flaky = fn conn ->
        if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0 do
          Req.Test.transport_error(conn, :econnrefused)
        else
          layer.plug.(conn)
        end
      end

      assert layer |> Map.put(:plug, flaky) |> collect() |> object_ids() == [1]
    end
  end

  describe "failures that are not transient" do
    for {name, answer, expected} <- [
          {"a 404", {404, "", []}, {:error, {:unexpected_status, 404}}},
          {"a 400", {400, "", []}, {:error, {:unexpected_status, 400}}},
          {"an error object with a 400 code", {200, ~s({"error":{"code":400}}), []},
           {:error, {:service_error, 400}}},
          {"a body that is no feature list", {200, ~s({"unrelated":true}), []},
           {:error, {:malformed, "features"}}},
          {"a body that is no JSON", {200, "<html>", []}, {:error, {:malformed, "root"}}}
        ] do
      test "#{name} is a value, and is asked for once" do
        answer = unquote(Macro.escape(answer))
        layer = start_layer([1], %{script: fn _number, _conn -> answer end})

        assert collect(layer) == [unquote(Macro.escape(expected))]
        assert Agent.get(layer.requests, & &1) == 1
      end
    end

    test "a feature with no OBJECTID is a malformed answer" do
      body = JSON.encode!(%{"features" => [%{"attributes" => %{"Name" => "x"}}]})
      layer = start_layer([1], %{script: fn _number, _conn -> {200, body, []} end})

      assert collect(layer) == [{:error, {:malformed, "features.0.attributes.OBJECTID"}}]
    end

    test "a page whose OBJECTIDs do not rise past the last is an error rather than a loop" do
      body =
        JSON.encode!(%{
          "features" => List.duplicate(feature(0), 100),
          "exceededTransferLimit" => true
        })

      layer = start_layer([1], %{script: fn _number, _conn -> {200, body, []} end})

      assert collect(layer) == [{:error, :no_progress}]
    end
  end
end
