defmodule Gobusgo.Addresses.FeaturePagesTest do
  # Checks the pure rules of paging a FeatureServer layer: the offsets a
  # record count gives, the query of one page, the reading of a page the
  # service answered (two pages recorded from King County's layer on
  # 2026-11-11), which failures are transient, and the delay before a retry.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.FeaturePages

  @pages Path.expand("../../fixtures/addresses/king_pages", __DIR__)
  @layer_url "https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @out_fields ["ADDR_HN", "ADDR_PD", "ADDR_SN", "ADDR_ST", "ADDR_SD", "POSTALCTYNAME"]

  defp recorded(name), do: File.read!(Path.join(@pages, name))

  describe "offsets/1" do
    for {record_count, offsets} <- [
          {0, []},
          {1, [0]},
          {100, [0]},
          {101, [0, 100]},
          {199, [0, 100]},
          {200, [0, 100]},
          {675_399, :last_675_300}
        ] do
      test "#{record_count} records are read from offsets #{inspect(offsets)}" do
        assert {:ok, offsets} = FeaturePages.offsets(unquote(record_count))

        case unquote(offsets) do
          :last_675_300 ->
            assert Enum.count(offsets) == 6_754
            assert Enum.at(offsets, -1) == 675_300

          expected ->
            assert Enum.to_list(offsets) == expected
        end
      end
    end

    test "a record count past the bound on pages is refused" do
      count = FeaturePages.record_count_max() + 1
      assert FeaturePages.offsets(count) == {:error, {:record_count_too_large, count}}
    end
  end

  describe "query_url/1" do
    test "asks for one page of the named fields in WGS 84, ordered by the object ID" do
      url = FeaturePages.query_url(%{layer_url: @layer_url, out_fields: @out_fields, offset: 300})
      %URI{path: path, query: query} = URI.parse(url)

      assert path ==
               "/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0/query"

      assert URI.decode_query(query) == %{
               "where" => "1=1",
               "outFields" => Enum.join(@out_fields, ","),
               "returnGeometry" => "true",
               "outSR" => "4326",
               "orderByFields" => "OBJECTID",
               "resultOffset" => "300",
               "resultRecordCount" => "100",
               "f" => "json"
             }
    end
  end

  describe "decode_page/2" do
    test "reads a full page's features in the order the service sent them" do
      assert {:ok, features} = FeaturePages.decode_page(recorded("offset_0.json"), @out_fields)
      assert length(features) == 100

      assert hd(features) == %{
               attributes: %{
                 "ADDR_HN" => "14243",
                 "ADDR_PD" => "SW",
                 "ADDR_SN" => "LISABEULA",
                 "ADDR_ST" => "RD",
                 "ADDR_SD" => nil,
                 "POSTALCTYNAME" => "VASHON"
               },
               lon: -122.51961713056957,
               lat: 47.40517878141594
             }
    end

    test "reads the layer's last page, which is short" do
      assert {:ok, features} =
               FeaturePages.decode_page(recorded("offset_675300.json"), @out_fields)

      assert length(features) == 99
    end

    test "a feature with no geometry has no position" do
      body = ~s({"features":[{"attributes":{"ADDR_HN":"1"},"geometry":null}]})

      assert {:ok, [%{lat: nil, lon: nil}]} = FeaturePages.decode_page(body, ["ADDR_HN"])
    end

    test "an error object the service answers with a 200 is the error's code" do
      body = ~s({"error":{"code":503,"message":"Service Unavailable","details":[]}})
      assert FeaturePages.decode_page(body, @out_fields) == {:error, {:service_error, 503}}
    end

    for {name, body, path} <- [
          {"a body that is no JSON", "<html>", "root"},
          {"a page with no features", ~s({"fields":[]}), "features"},
          {"a field that is no text", ~s({"features":[{"attributes":{"ADDR_HN":1}}]}),
           "features.0.attributes.ADDR_HN"}
        ] do
      test "#{name} is malformed" do
        assert FeaturePages.decode_page(unquote(body), ["ADDR_HN"]) ==
                 {:error, {:malformed, unquote(path)}}
      end
    end

    test "a page of more features than were asked for is refused" do
      feature = ~s({"attributes":{"ADDR_HN":"1"}})
      body = ~s({"features":[#{Enum.map_join(1..101, ",", fn _index -> feature end)}]})

      assert FeaturePages.decode_page(body, ["ADDR_HN"]) == {:error, {:page_too_large, 101}}
    end
  end

  describe "transient?/1" do
    for failure <- [
          {:unexpected_status, 408},
          {:unexpected_status, 429},
          {:unexpected_status, 500},
          {:unexpected_status, 503},
          {:service_error, 504},
          {:transport, :timeout},
          :deadline_exceeded
        ] do
      test "#{inspect(failure)} is transient" do
        assert FeaturePages.transient?(unquote(Macro.escape(failure)))
      end
    end

    for failure <- [
          {:unexpected_status, 400},
          {:unexpected_status, 404},
          {:service_error, 400},
          {:malformed, "features"},
          {:page_too_large, 101},
          :body_too_large
        ] do
      test "#{inspect(failure)} is not transient" do
        refute FeaturePages.transient?(unquote(Macro.escape(failure)))
      end
    end
  end

  describe "retry_delay_ms/1" do
    defp delay(overrides) do
      FeaturePages.retry_delay_ms(
        Map.merge(
          %{attempt_index: 0, base_ms: 1_000, cap_ms: 16_000, retry_after_ms: nil, jitter: 1.0},
          Map.new(overrides)
        )
      )
    end

    test "doubles from the base with each attempt, up to the cap" do
      assert Enum.map(0..5, &delay(attempt_index: &1)) ==
               [1_000, 2_000, 4_000, 8_000, 16_000, 16_000]
    end

    test "jitter takes a share of the delay" do
      assert delay(attempt_index: 1, jitter: 0.5) == 1_000
      assert delay(attempt_index: 1, jitter: 0.0) == 0
    end

    test "a Retry-After the service sends replaces the computed delay" do
      assert delay(attempt_index: 0, retry_after_ms: 7_000) == 7_000
    end

    test "a Retry-After past the cap waits the cap" do
      assert delay(attempt_index: 0, retry_after_ms: 600_000) == 16_000
    end
  end

  describe "retry_after_ms/1" do
    for {header, expected} <- [{"3", 3_000}, {"0", 0}, {nil, nil}, {"soon", nil}] do
      test "#{inspect(header)} is #{inspect(expected)}" do
        assert FeaturePages.retry_after_ms(unquote(header)) == unquote(expected)
      end
    end
  end
end
