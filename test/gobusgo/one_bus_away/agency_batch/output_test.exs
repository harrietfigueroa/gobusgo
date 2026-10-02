defmodule Gobusgo.OneBusAway.AgencyBatch.OutputTest do
  # Verifies the published form of a batch as a pure function of its inputs:
  # the destination and the content are compared with hand-written literals,
  # and the duplicate and latest-response rules with small input lists.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.AgencyBatch.Output

  @window %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
  @batch_id "20261002T000000Z-20261003T000000Z"
  @processed_at ~U[2026-10-03 00:05:00Z]
  @trigger_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @partition "raw/oba/agencies-with-coverage/dt=2026-10-02/"

  defp agency(id) do
    %{
      id: id,
      name: "Agency #{id}",
      url: "https://agency-#{id}.example.test",
      timezone: "America/Los_Angeles",
      coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
    }
  end

  defp input(minute, hash_character, agencies) do
    stamp = "20261002T00#{String.pad_leading("#{minute}", 2, "0")}00Z"
    {:ok, fetched_at, 0} = DateTime.from_iso8601(stamp, :basic)

    %{
      destination: "#{@partition}#{stamp}_request-#{minute}_#{hash_character}.json",
      fetched_at: fetched_at,
      data_sha256: String.duplicate(hash_character, 64),
      agencies: agencies
    }
  end

  defp build(overrides \\ %{}) do
    Output.build(
      Map.merge(
        %{
          window: @window,
          inputs: [input(1, "a", [agency("1")])],
          skipped: [],
          processed_at: @processed_at,
          trigger_id: @trigger_id
        },
        overrides
      )
    )
  end

  defp meta(output), do: output.content |> JSON.decode!() |> Map.fetch!("meta")

  describe "destination_prefix/1" do
    test "starts every output of a batch" do
      assert Output.destination_prefix(@batch_id) == "processed/oba/agencies/#{@batch_id}_"
      assert String.starts_with?(build().destination, Output.destination_prefix(@batch_id))
    end
  end

  describe "build/1 destination" do
    test "is the batch, the first and last fetch times, and the processing time" do
      inputs = [input(1, "a", [agency("1")]), input(7, "b", [agency("1")])]

      assert build(%{inputs: inputs}).destination ==
               "processed/oba/agencies/#{@batch_id}_20261002T000100Z_20261002T000700Z_20261003T000500Z.json"
    end

    test "obeys the logical destination rules" do
      assert {:ok, _segments} = Destination.validate(build().destination)
    end
  end

  describe "build/1 content" do
    test "is the agencies and the meta as compact JSON with sorted keys" do
      skipped = [%{destination: "#{@partition}notes.json", reason: :destination_mismatch}]

      assert build(%{skipped: skipped}).content ==
               ~s({"agencies":[{"coverage":{"lat":47.5,"latSpan":0.5,"lon":-122.25,"lonSpan":0.75},) <>
                 ~s("id":"1","name":"Agency 1","timezone":"America/Los_Angeles",) <>
                 ~s("url":"https://agency-1.example.test"}],) <>
                 ~s("meta":{"batchId":"#{@batch_id}","inputFileCount":2,) <>
                 ~s("inputs":[{"dataSha256":"#{String.duplicate("a", 64)}",) <>
                 ~s("destination":"#{@partition}20261002T000100Z_request-1_a.json",) <>
                 ~s("duplicate":false,"fetchedAt":"2026-10-02T00:01:00Z"}],) <>
                 ~s("processedAt":"2026-10-03T00:05:00Z","schemaVersion":1,) <>
                 ~s("skipped":[{"destination":"#{@partition}notes.json",) <>
                 ~s("reason":"destination_mismatch"}],) <>
                 ~s("triggerId":"#{@trigger_id}",) <>
                 ~s("windowEnd":"2026-10-03T00:00:00Z","windowStart":"2026-10-02T00:00:00Z"}})
    end

    test "takes the agencies from the latest input, sorted by identifier" do
      inputs = [
        input(1, "a", [agency("1")]),
        input(2, "b", [agency("40"), agency("3"), agency("1")])
      ]

      assert %{"agencies" => agencies} = JSON.decode!(build(%{inputs: inputs}).content)
      assert Enum.map(agencies, & &1["id"]) == ["1", "3", "40"]
    end

    test "flags an input whose data hash an earlier input carries" do
      inputs = [
        input(1, "a", [agency("1")]),
        input(2, "b", [agency("1")]),
        input(3, "a", [agency("1")]),
        input(4, "a", [agency("1")])
      ]

      output = build(%{inputs: inputs})

      assert Enum.map(meta(output)["inputs"], & &1["duplicate"]) == [false, false, true, true]
      assert output.duplicate_count == 2
    end

    test "counts the valid and the skipped inputs together" do
      skipped = [
        %{destination: "#{@partition}x.json", reason: :invalid_json},
        %{destination: "#{@partition}y.json", reason: :hash_mismatch}
      ]

      assert meta(build(%{skipped: skipped}))["inputFileCount"] == 3
    end
  end

  describe "build/1 assertions" do
    test "raises without inputs" do
      assert_raise AssertionError, ~r/input/, fn -> build(%{inputs: []}) end
    end

    test "raises for inputs out of destination order" do
      inputs = [input(2, "b", [agency("1")]), input(1, "a", [agency("1")])]

      assert_raise AssertionError, ~r/order/, fn -> build(%{inputs: inputs}) end
    end

    test "raises for a trigger identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/trigger/, fn -> build(%{trigger_id: "trigger"}) end
    end

    test "raises for a processing time with a fraction of a second" do
      assert_raise AssertionError, ~r/whole second/, fn ->
        build(%{processed_at: ~U[2026-10-03 00:05:00.250Z]})
      end
    end
  end
end
