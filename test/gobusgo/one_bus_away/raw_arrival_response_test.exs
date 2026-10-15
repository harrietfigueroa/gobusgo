defmodule Gobusgo.OneBusAway.RawArrivalResponseTest do
  # Verifies the stored form of an arrivals response as a pure function of the
  # response and the request identifier. Destinations and `meta` are written
  # out by hand, and parse/1 is driven with content build/1 produced from the
  # fixture cut from a live response, then altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.Arrivals

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp envelope(name \\ "arrivals_and_departures_for_stop") do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp response(overrides) do
    Map.merge(
      %{
        stop_id: "95_7",
        arrivals: nil,
        envelope: envelope(),
        fetched_at: ~U[2026-10-02 03:15:00.987654Z],
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      },
      overrides
    )
  end

  defp build(overrides \\ %{}) do
    RawArrivalResponse.build(%{response: response(overrides), request_id: @request_id})
  end

  defp parse(stored, changes \\ %{}) do
    RawArrivalResponse.parse(Map.merge(Map.take(stored, [:destination, :content]), changes))
  end

  defp alter(content, path, value) do
    content |> JSON.decode!() |> put_in(path, value) |> Gobusgo.CanonicalJson.encode()
  end

  describe "build/1 destination" do
    test "is the date partition, the stop, fetch time, request identifier, and hash prefix" do
      stored = build()

      assert stored.destination ==
               "raw/oba/arrivals-and-departures-for-stop/dt=2026-10-02/stop=95_7/" <>
                 "20261002T031500Z_#{@request_id}_#{binary_part(stored.data_sha256, 0, 12)}.json.gz"
    end

    for {stop_id, segment} <- [
          {"KCM_1-a", "stop=KCM_1-a"},
          {"a/b", "stop=a.2Fb"},
          {"1.5", "stop=1.2E5"},
          {"é", "stop=.C3.A9"},
          {"a=b", "stop=a.3Db"}
        ] do
      test "names the stop #{inspect(stop_id)} as #{segment}" do
        stored = build(%{stop_id: unquote(stop_id)})

        assert stored.destination =~ "/dt=2026-10-02/#{unquote(segment)}/20261002T031500Z_"
        assert {:ok, _segments} = Destination.validate(stored.destination)
      end
    end
  end

  describe "build/1 content" do
    test "holds the stop beside the shared meta fields" do
      stored = build()

      assert JSON.decode!(stored.content)["meta"] == %{
               "stopId" => "95_7",
               "dataSha256" => stored.data_sha256,
               "envelopeCurrentTime" => envelope()["currentTime"],
               "envelopeVersion" => 2,
               "fetchedAt" => "2026-10-02T03:15:00Z",
               "host" => "oba.example.test",
               "httpStatus" => 200,
               "method" => "GET",
               "requestId" => @request_id
             }
    end

    test "keeps the envelope unchanged under body" do
      assert JSON.decode!(build().content)["body"] == envelope()
    end

    test "hashes the envelope data in its canonical encoding" do
      canonical = Gobusgo.CanonicalJson.encode(envelope()["data"])

      assert build().data_sha256 == sha256(canonical)
    end
  end

  describe "build/1 assertions" do
    test "raises for an empty stop identifier" do
      assert_raise AssertionError, fn -> build(%{stop_id: ""}) end
    end

    test "raises for a stop identifier too long for a destination segment" do
      assert_raise AssertionError, fn -> build(%{stop_id: String.duplicate("a", 200)}) end
    end
  end

  describe "parse/1" do
    test "returns the fetch build/1 stored, arrivals included" do
      stored = build()
      {:ok, arrivals} = Arrivals.parse(envelope()["data"], "95_7")

      assert parse(stored) ==
               {:ok,
                %{
                  stop_id: "95_7",
                  destination: stored.destination,
                  fetched_at: ~U[2026-10-02 03:15:00Z],
                  data_sha256: stored.data_sha256,
                  request_id: @request_id,
                  arrivals: arrivals,
                  situations: [],
                  situation_rejected_count: 0
                }}
    end

    test "returns the situations the response references, with the count rejected" do
      situations = get_in(envelope("situations"), ["references", "situations"])
      [first | rest] = situations
      referenced = [Map.put(first, "id", "") | rest]
      altered = put_in(envelope(), ["data", "references", "situations"], referenced)

      assert {:ok, %{situations: parsed, situation_rejected_count: 1}} =
               parse(build(%{envelope: altered}))

      assert Enum.map(parsed, & &1.id) == Enum.map(rest, & &1["id"])
    end

    test "rejects content that is not JSON" do
      assert parse(build(), %{content: "{"}) == {:error, :invalid_json}
    end

    test "rejects data that does not hash to the recorded hash" do
      stored = build()
      content = alter(stored.content, ["body", "data", "limitExceeded"], true)

      assert parse(stored, %{content: content}) == {:error, :hash_mismatch}
    end

    test "rejects a meta without a stop" do
      stored = build()
      content = stored.content |> JSON.decode!() |> pop_in(["meta", "stopId"]) |> elem(1)

      assert parse(stored, %{content: Gobusgo.CanonicalJson.encode(content)}) ==
               {:error, :schema_mismatch}
    end

    for stop_id <- ["", 40] do
      test "rejects the stop #{inspect(stop_id)} in meta" do
        stored = build()
        content = alter(stored.content, ["meta", "stopId"], unquote(stop_id))

        assert parse(stored, %{content: content}) == {:error, :schema_mismatch}
      end
    end

    test "rejects content stored under another stop's destination" do
      stored = build()
      content = alter(stored.content, ["meta", "stopId"], "1")

      assert parse(stored, %{content: content}) == {:error, :destination_mismatch}
    end

    test "rejects content read from another destination" do
      stored = build()
      other = String.replace(stored.destination, "dt=2026-10-02", "dt=2026-10-03")

      assert parse(stored, %{destination: other}) == {:error, :destination_mismatch}
    end

    test "rejects data that is not the arrivals at a stop" do
      stored = build(%{envelope: envelope("arrivals_and_departures_for_stop_schema_violation")})

      assert parse(stored) == {:error, :schema_mismatch}
    end
  end
end
