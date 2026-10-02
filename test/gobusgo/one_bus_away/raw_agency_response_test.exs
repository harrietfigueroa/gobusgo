defmodule Gobusgo.OneBusAway.RawAgencyResponseTest do
  # Verifies the stored form of an agency response as a pure function of the
  # response and the request identifier: expected destinations, content, and
  # hashes are written out by hand, so the encoder is checked against literals
  # and never against itself.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.RawAgencyResponse

  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @data_canonical ~s({"a":[1.5,"x"],"b":1})

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => %{"b" => 1, "a" => [1.5, "x"]},
        "text" => "OK",
        "version" => 2
      },
      overrides
    )
  end

  defp response(overrides) do
    Map.merge(
      %{
        agencies: [],
        envelope: envelope(),
        fetched_at: ~U[2026-10-02 03:15:00.987654Z],
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      },
      overrides
    )
  end

  defp build(overrides \\ %{}, request_id \\ @request_id) do
    RawAgencyResponse.build(%{response: response(overrides), request_id: request_id})
  end

  describe "build/1 destination" do
    test "is the date partition, fetch time, request identifier, and hash prefix" do
      hash_prefix = @data_canonical |> sha256() |> binary_part(0, 12)

      assert build().destination ==
               "raw/oba/agencies-with-coverage/dt=2026-10-02/" <>
                 "20261002T031500Z_#{@request_id}_#{hash_prefix}.json"
    end

    test "partitions by the UTC date of the fetch time" do
      stored = build(%{fetched_at: ~U[2026-12-31 23:59:59Z]})

      assert stored.destination =~ "/dt=2026-12-31/20261231T235959Z_"
    end

    test "obeys the logical destination rules" do
      assert {:ok, _segments} = Destination.validate(build().destination)
    end
  end

  describe "build/1 content" do
    test "is the wrapper as compact JSON with sorted keys" do
      assert build().content ==
               ~s({"body":{"code":200,"currentTime":1710953797130,) <>
                 ~s("data":#{@data_canonical},"text":"OK","version":2},) <>
                 ~s("meta":{"dataSha256":"#{sha256(@data_canonical)}",) <>
                 ~s("envelopeCurrentTime":1710953797130,"envelopeVersion":2,) <>
                 ~s("fetchedAt":"2026-10-02T03:15:00Z","host":"oba.example.test",) <>
                 ~s("httpStatus":200,"method":"GET","requestId":"#{@request_id}"}})
    end

    test "keeps the envelope unchanged under body" do
      assert %{"body" => body} = JSON.decode!(build().content)
      assert body == envelope()
    end
  end

  describe "build/1 returned facts" do
    test "returns the fetch time at the second precision it stores" do
      assert build().fetched_at == ~U[2026-10-02 03:15:00Z]
    end

    test "returns the hash of the envelope data" do
      assert build().data_sha256 == sha256(@data_canonical)
    end
  end

  describe "data_sha256/1" do
    test "hashes keys in sorted order for a map of any size" do
      data = Map.new(1..40, fn index -> {"k#{index}", index} end)

      canonical =
        data
        |> Enum.sort()
        |> Enum.map_join(",", fn {key, value} -> ~s("#{key}":#{value}) end)

      assert RawAgencyResponse.data_sha256(data) == sha256("{" <> canonical <> "}")
    end

    test "is unchanged by the envelope time" do
      later = envelope(%{"currentTime" => 1_710_953_800_000})

      assert build(%{envelope: later}).data_sha256 == build().data_sha256
    end

    test "changes when the data changes" do
      changed = envelope(%{"data" => %{"b" => 2, "a" => [1.5, "x"]}})

      assert build(%{envelope: changed}).data_sha256 != build().data_sha256
    end
  end

  describe "build/1 assertions" do
    for {name, overrides, pattern} <- [
          {"an HTTP status other than 200", %{http_status: 500}, ~r/HTTP status/},
          {"an empty host", %{host: ""}, ~r/host/},
          {"a fetch time outside UTC",
           %{
             fetched_at: %{
               ~U[2026-10-02 03:15:00Z]
               | utc_offset: 3600,
                 time_zone: "Europe/Paris",
                 zone_abbr: "CET"
             }
           }, ~r/UTC/}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          build(unquote(Macro.escape(overrides)))
        end
      end
    end

    test "raises for an envelope code other than 200" do
      assert_raise AssertionError, fn -> build(%{envelope: envelope(%{"code" => 500})}) end
    end

    test "raises for an envelope without data" do
      assert_raise AssertionError, fn ->
        build(%{envelope: Map.delete(envelope(), "data")})
      end
    end

    test "raises for a request identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/request identifier/, fn ->
        build(%{}, "0199c4a2-7e1b-4a3f-9d20-5b6c1e8f4a10")
      end
    end

    test "raises when the meta carries a key parameter" do
      assert_raise AssertionError, ~r/meta carries a key=/, fn ->
        build(%{host: "oba.example.test/?key=placeholder"})
      end
    end

    test "keeps the meta out of the message raised for a key parameter" do
      exception =
        assert_raise AssertionError, fn ->
          build(%{host: "oba.example.test/?key=placeholder"})
        end

      refute exception.message =~ "placeholder"
    end
  end

  describe "build/1 agency-supplied text" do
    test "stores a body whose data carries a key parameter" do
      linking = envelope(%{"data" => %{"url" => "https://agency.example.test/?key=placeholder"}})

      assert %{"body" => body} = JSON.decode!(build(%{envelope: linking}).content)
      assert body == linking
    end
  end
end
