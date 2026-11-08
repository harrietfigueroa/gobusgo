defmodule Gobusgo.OneBusAway.RouteScheduleBatchTest do
  # Drives process/2 through reader and publisher doubles defined here, so
  # every outcome is observed through the reader and publisher contracts with
  # no storage and no broker. The stored response is produced by
  # RawRouteScheduleResponse.build/1 from the live fixture, the form the
  # recorder writes.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteSchedules

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => {:error, reason}} -> {:error, reason}
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
      Keyword.fetch!(options, :result)
    end
  end

  @fixture_path Path.expand("../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @fetched_at ~U[2026-11-06 23:15:00Z]

  defp stored do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()
    {:ok, schedule} = RouteSchedules.parse(envelope["data"], "19_41")

    RawRouteScheduleResponse.build(%{
      request_id: @request_id,
      response: %{
        route_id: "19_41",
        service_date: ~D[2026-11-07],
        schedule: schedule,
        envelope: envelope,
        fetched_at: @fetched_at,
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      }
    })
  end

  # The backend holds a gzip stream under a compressed destination.
  defp held({:error, reason}), do: {:error, reason}
  defp held(content) when is_binary(content), do: :zlib.gzip(content)

  defp process(destination, content, result \\ :ok) do
    RouteScheduleBatch.process(destination,
      read_options: [backend: StoredContent, stored: %{destination => held(content)}],
      publish_options: [backend: RecordingPublisher, recipient: self(), result: result]
    )
  end

  describe "process/2 success" do
    test "publishes one schedule record" do
      %{destination: destination, content: content} = stored()

      {:ok, _result} = process(destination, content)

      assert_received {:published,
                       [
                         %{
                           topic: "oba.schedules.state",
                           key: "schedule-for-route/19_41/2026-11-07"
                         }
                       ]}
    end

    test "returns the fetch and what it holds" do
      %{destination: destination, content: content} = stored()

      assert process(destination, content) ==
               {:ok,
                %{
                  destination: destination,
                  route_id: "19_41",
                  service_date: ~D[2026-11-07],
                  request_id: @request_id,
                  fetched_at: @fetched_at,
                  trip_count: 2,
                  stop_time_count: 64
                }}
    end

    test "logs the publication at debug" do
      %{destination: destination, content: content} = stored()

      log = capture_log([level: :debug], fn -> process(destination, content) end)

      assert log =~ "Route schedule batch published"
    end
  end

  describe "process/2 failures" do
    test "returns a read failure for a response that is not there" do
      %{destination: destination} = stored()

      assert {:error, %{stage: :read, reason: :not_found, class: :permanent}} =
               process(destination, {:error, :not_found})

      refute_received {:published, _records}
    end

    test "returns a permanent parse failure for content that is not a stored response" do
      %{destination: destination} = stored()

      assert {:error, %{stage: :parse, reason: :schema_mismatch, class: :permanent}} =
               process(destination, ~s({"meta": {}, "body": {}}))

      refute_received {:published, _records}
    end

    test "returns a publish failure for a publisher that is unavailable" do
      %{destination: destination, content: content} = stored()

      assert process(destination, content, {:error, :unavailable}) ==
               {:error,
                %{
                  stage: :publish_route_schedule,
                  reason: :unavailable,
                  error_code: "WRITE_FAILURE",
                  class: :transient
                }}
    end
  end
end
