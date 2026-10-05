defmodule Gobusgo.OneBusAway.RouteDatasetsTest do
  # Verifies that the two route datasets behave as one for a consumer of
  # their shared topic: decode/1 is driven with the events each dataset
  # builds, and process/2 with a reader double that says which stored
  # response was asked for and a publisher double that records what the
  # chosen processor published.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RouteDatasets

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      :ok
    end
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @fetched_at ~U[2026-10-05 01:17:31Z]

  defp response(fixture, fields) do
    Map.merge(
      %{
        envelope:
          @fixture_directory |> Path.join(fixture <> ".json") |> File.read!() |> JSON.decode!(),
        fetched_at: @fetched_at,
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      },
      fields
    )
  end

  defp stored_routes do
    RawRouteResponse.build(%{
      request_id: @request_id,
      response: response("routes_for_agency", %{agency_id: "40", routes: nil})
    })
  end

  defp stored_route_path do
    RawRoutePathResponse.build(%{
      request_id: @request_id,
      response: response("stops_for_route", %{route_id: "1_100336", route_path: nil})
    })
  end

  defp event(module, stored, fields) do
    module.record(%{
      event_id: @event_id,
      source: "/gobusgo/test",
      time: @fetched_at,
      response:
        Map.merge(
          %{
            destination: stored.destination,
            fetched_at: stored.fetched_at,
            data_sha256: stored.data_sha256,
            request_id: @request_id
          },
          fields
        )
    })
  end

  defp process(%{destination: destination, content: content}) do
    RouteDatasets.process(destination,
      # The backend holds a gzip stream under a compressed destination.
      read_options: [backend: StoredContent, stored: %{destination => :zlib.gzip(content)}],
      publish_options: [backend: RecordingPublisher, recipient: self()]
    )
  end

  test "names the topic both datasets announce on" do
    assert RouteDatasets.topic() == "oba.routes.response-stored"
    assert RawRouteResponse.StoredEvent.topic() == RouteDatasets.topic()
    assert RawRoutePathResponse.StoredEvent.topic() == RouteDatasets.topic()
  end

  describe "decode/1" do
    test "returns the event of an agency's routes" do
      stored = stored_routes()
      record = event(RawRouteResponse.StoredEvent, stored, %{agency_id: "40"})

      assert {:ok, %{agency_id: "40", destination: destination, request_id: @request_id}} =
               RouteDatasets.decode(record.value)

      assert destination == stored.destination
    end

    test "returns the event of a route's paths" do
      stored = stored_route_path()
      record = event(RawRoutePathResponse.StoredEvent, stored, %{route_id: "1_100336"})

      assert {:ok, %{route_id: "1_100336", destination: destination}} =
               RouteDatasets.decode(record.value)

      assert destination == stored.destination
    end

    test "rejects the event of a dataset that is not a route dataset" do
      record = event(RawAgencyResponse.StoredEvent, stored_routes(), %{})

      assert RouteDatasets.decode(record.value) == {:error, :schema_mismatch}
    end

    test "rejects a value that is not JSON" do
      assert RouteDatasets.decode("{") == {:error, :invalid_json}
    end
  end

  describe "process/2" do
    test "publishes an agency's routes for a stored routes response" do
      assert {:ok, %{agency_id: "40", route_count: 3}} = process(stored_routes())
      assert_received {:published, [%{key: "routes-for-agency/40"}]}
    end

    test "publishes a route's paths for a stored route path response" do
      assert {:ok, %{route_id: "1_100336"}} = process(stored_route_path())

      assert_received {:published,
                       [%{topic: "oba.routes.state", key: "stops-for-route/1_100336"} | _stops]}
    end

    test "returns a permanent failure for a destination of neither dataset" do
      stored = %{
        destination: "raw/oba/vehicles-for-agency/dt=2026-10-05/file.json.gz",
        content: ""
      }

      assert process(stored) ==
               {:error,
                %{
                  stage: :parse,
                  reason: :destination_mismatch,
                  error_code: "DESTINATION_MISMATCH",
                  class: :permanent
                }}

      refute_received {:published, _records}
    end
  end
end
