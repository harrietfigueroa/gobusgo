defmodule Gobusgo.OneBusAway.AgencyBatch.RecordsTest do
  # Verifies the published form of a fetch as a pure function of the parsed
  # stored response: expected keys and events are written out by hand and
  # compared with the decoded records.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyBatch.Records

  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/agencies-with-coverage/dt=2026-10-02/" <>
                 "20261002T031500Z_#{@request_id}_abababababab.json"
  @data_sha256 String.duplicate("ab", 32)
  @topic "oba.agencies-with-coverage.state"
  @source "/gobusgo/processor/oba/agencies-with-coverage"
  @headers [{"content-type", "application/cloudevents+json"}]

  defp agency(id, name) do
    %{
      id: id,
      name: name,
      url: "https://#{id}.example.test",
      timezone: "America/Los_Angeles",
      coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
    }
  end

  defp parsed(agencies) do
    %{
      destination: @destination,
      fetched_at: ~U[2026-10-02 03:15:00Z],
      data_sha256: @data_sha256,
      request_id: @request_id,
      agencies: agencies
    }
  end

  describe "build/1 agency records" do
    test "holds one record per agency, in identifier order, keyed by prefixed identifier" do
      %{agencies: records} =
        Records.build(parsed([agency("40", "Regional Transit"), agency("1", "Metro Transit")]))

      assert Enum.map(records, &Map.take(&1, [:topic, :key, :headers])) == [
               %{topic: @topic, key: "agency/1", headers: @headers},
               %{topic: @topic, key: "agency/40", headers: @headers}
             ]
    end

    test "carries the agency, the fetch time, and the request identifier as a CloudEvent" do
      %{agencies: [record]} = Records.build(parsed([agency("1", "Metro Transit")]))

      assert JSON.decode!(record.value) == %{
               "specversion" => "1.0",
               "id" => "#{@request_id}/agency/1",
               "source" => @source,
               "type" => "gobusgo.agency.processed.v1",
               "time" => "2026-10-02T03:15:00Z",
               "subject" => "1",
               "datacontenttype" => "application/json",
               "partitionkey" => "agency/1",
               "data" => %{
                 "agency" => %{
                   "id" => "1",
                   "name" => "Metro Transit",
                   "url" => "https://1.example.test",
                   "timezone" => "America/Los_Angeles",
                   "coverage" => %{
                     "lat" => 47.5,
                     "lon" => -122.25,
                     "latSpan" => 0.5,
                     "lonSpan" => 0.75
                   }
                 },
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "requestId" => @request_id
               }
             }
    end

    test "is empty for a fetch without agencies" do
      assert %{agencies: []} = Records.build(parsed([]))
    end
  end

  describe "build/1 manifest record" do
    test "names every agency of the fetch, sorted, under the manifest key" do
      %{manifest: record} =
        Records.build(parsed([agency("40", "Regional Transit"), agency("1", "Metro Transit")]))

      assert Map.take(record, [:topic, :key, :headers]) ==
               %{topic: @topic, key: "manifest", headers: @headers}

      assert JSON.decode!(record.value) == %{
               "specversion" => "1.0",
               "id" => "#{@request_id}/manifest",
               "source" => @source,
               "type" => "gobusgo.agency.fetch.completed.v1",
               "time" => "2026-10-02T03:15:00Z",
               "subject" => @destination,
               "datacontenttype" => "application/json",
               "partitionkey" => "manifest",
               "data" => %{
                 "agencyIds" => ["1", "40"],
                 "dataSha256" => @data_sha256,
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "requestId" => @request_id
               }
             }
    end

    test "lists no agency for a fetch without agencies" do
      %{manifest: record} = Records.build(parsed([]))

      assert JSON.decode!(record.value)["data"]["agencyIds"] == []
    end
  end

  describe "build/1 determinism" do
    test "yields the same bytes whatever the order of the agencies" do
      agencies = [agency("40", "Regional Transit"), agency("1", "Metro Transit")]

      assert Records.build(parsed(agencies)) == Records.build(parsed(Enum.reverse(agencies)))
    end
  end

  describe "build/1 assertions" do
    test "raises for a request identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/request identifier/, fn ->
        Records.build(%{parsed([]) | request_id: "request"})
      end
    end

    test "raises for an agency listed twice" do
      assert_raise AssertionError, ~r/unique/, fn ->
        Records.build(parsed([agency("1", "Metro Transit"), agency("1", "Metro Transit")]))
      end
    end
  end
end
