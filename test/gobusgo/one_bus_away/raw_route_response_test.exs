defmodule Gobusgo.OneBusAway.RawRouteResponseTest do
  # Verifies the stored form of a route response as a pure function of the
  # response and the request identifier. Destinations and `meta` are written
  # out by hand, and parse/1 is driven with content build/1 produced from the
  # fixture cut from a live response, then altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.Routes

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp envelope(name \\ "routes_for_agency") do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp response(overrides) do
    Map.merge(
      %{
        agency_id: "40",
        routes: [],
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
    RawRouteResponse.build(%{response: response(overrides), request_id: @request_id})
  end

  defp parse(stored, changes \\ %{}) do
    RawRouteResponse.parse(Map.merge(Map.take(stored, [:destination, :content]), changes))
  end

  defp alter(content, path, value) do
    content |> JSON.decode!() |> put_in(path, value) |> Gobusgo.CanonicalJson.encode()
  end

  describe "build/1 destination" do
    test "is the date partition, the agency, fetch time, request identifier, and hash prefix" do
      stored = build()

      assert stored.destination ==
               "raw/oba/routes-for-agency/dt=2026-10-02/agency=40/" <>
                 "20261002T031500Z_#{@request_id}_#{binary_part(stored.data_sha256, 0, 12)}.json.gz"
    end

    for {agency_id, segment} <- [
          {"KCM_1-a", "agency=KCM_1-a"},
          {"a/b", "agency=a.2Fb"},
          {"1.5", "agency=1.2E5"},
          {"é", "agency=.C3.A9"},
          {"a=b", "agency=a.3Db"}
        ] do
      test "names the agency #{inspect(agency_id)} as #{segment}" do
        stored = build(%{agency_id: unquote(agency_id)})

        assert stored.destination =~ "/dt=2026-10-02/#{unquote(segment)}/20261002T031500Z_"
        assert {:ok, _segments} = Destination.validate(stored.destination)
      end
    end
  end

  describe "build/1 content" do
    test "holds the agency beside the shared meta fields" do
      stored = build()

      assert JSON.decode!(stored.content)["meta"] == %{
               "agencyId" => "40",
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
    test "raises for an empty agency identifier" do
      assert_raise AssertionError, fn -> build(%{agency_id: ""}) end
    end

    test "raises for an agency identifier too long for a destination segment" do
      assert_raise AssertionError, fn -> build(%{agency_id: String.duplicate("a", 200)}) end
    end
  end

  describe "parse/1" do
    test "returns the fetch build/1 stored, routes included" do
      stored = build()
      {:ok, routes} = Routes.parse(envelope()["data"], "40")

      assert parse(stored) ==
               {:ok,
                %{
                  agency_id: "40",
                  destination: stored.destination,
                  fetched_at: ~U[2026-10-02 03:15:00Z],
                  data_sha256: stored.data_sha256,
                  request_id: @request_id,
                  routes: routes
                }}
    end

    test "returns a fetch without routes for an agency that has none" do
      stored = build(%{envelope: envelope("routes_for_agency_empty")})

      assert {:ok, %{routes: []}} = parse(stored)
    end

    test "rejects content that is not JSON" do
      assert parse(build(), %{content: "{"}) == {:error, :invalid_json}
    end

    test "rejects data that does not hash to the recorded hash" do
      stored = build()
      content = alter(stored.content, ["body", "data", "limitExceeded"], true)

      assert parse(stored, %{content: content}) == {:error, :hash_mismatch}
    end

    test "rejects a meta without an agency" do
      stored = build()
      content = stored.content |> JSON.decode!() |> pop_in(["meta", "agencyId"]) |> elem(1)

      assert parse(stored, %{content: Gobusgo.CanonicalJson.encode(content)}) ==
               {:error, :schema_mismatch}
    end

    for agency_id <- ["", 40] do
      test "rejects the agency #{inspect(agency_id)} in meta" do
        stored = build()
        content = alter(stored.content, ["meta", "agencyId"], unquote(agency_id))

        assert parse(stored, %{content: content}) == {:error, :schema_mismatch}
      end
    end

    test "rejects content stored under another agency's destination" do
      stored = build()
      content = alter(stored.content, ["meta", "agencyId"], "1")

      assert parse(stored, %{content: content}) == {:error, :destination_mismatch}
    end

    test "rejects content read from another destination" do
      stored = build()
      other = String.replace(stored.destination, "dt=2026-10-02", "dt=2026-10-03")

      assert parse(stored, %{destination: other}) == {:error, :destination_mismatch}
    end

    test "rejects data that is not route data" do
      stored = build(%{envelope: envelope("routes_for_agency_duplicate_route")})

      assert parse(stored) == {:error, :schema_mismatch}
    end
  end
end
