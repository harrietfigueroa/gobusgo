defmodule Gobusgo.OneBusAway.RouteBatchTest do
  # Drives process/2 through reader and publisher doubles defined here, so
  # every outcome is observed through the reader and publisher contracts with
  # no storage and no broker. The stored response is produced by
  # RawRouteResponse.build/1 from the live fixture, the form the recorder
  # writes. The log cases count the lines of a whole capture, which holds
  # the lines of every test running at the time, hence the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RawRouteResponse

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

  @fixture_path Path.expand("../../fixtures/one_bus_away/routes_for_agency.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-10-05 01:17:31Z]

  defp stored do
    RawRouteResponse.build(%{
      request_id: @request_id,
      response: %{
        agency_id: "40",
        routes: nil,
        envelope: @fixture_path |> File.read!() |> JSON.decode!(),
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
    RouteBatch.process(destination,
      read_options: [backend: StoredContent, stored: %{destination => held(content)}],
      publish_options: [backend: RecordingPublisher, recipient: self(), result: result]
    )
  end

  describe "process/2 success" do
    test "publishes one record for the stored response" do
      %{destination: destination, content: content} = stored()

      assert {:ok, _result} = process(destination, content)

      assert_received {:published, [%{topic: "oba.routes.state", key: "routes-for-agency/40"}]}
    end

    test "returns the fetch and what it holds" do
      %{destination: destination, content: content} = stored()

      assert process(destination, content) ==
               {:ok,
                %{
                  destination: destination,
                  agency_id: "40",
                  request_id: @request_id,
                  fetched_at: @fetched_at,
                  route_count: 3
                }}
    end

    test "publishes the same record again for a repeated call" do
      %{destination: destination, content: content} = stored()

      {:ok, _first} = process(destination, content)
      {:ok, _second} = process(destination, content)

      assert_received {:published, [record]}
      assert_received {:published, [^record]}
    end

    test "logs the publication once at info" do
      %{destination: destination, content: content} = stored()

      log = capture_log([level: :info], fn -> process(destination, content) end)

      assert length(String.split(log, "Route batch published")) == 2
    end
  end

  describe "process/2 failures" do
    for {name, reason, class} <- [
          {"a response that is not there", :not_found, :permanent},
          {"a read that fails", :io_failure, :transient}
        ] do
      test "returns a read failure for #{name}" do
        %{destination: destination} = stored()

        assert process(destination, {:error, unquote(reason)}) ==
                 {:error,
                  %{
                    stage: :read,
                    reason: unquote(reason),
                    error_code: "READ_FAILURE",
                    class: unquote(class)
                  }}

        refute_received {:published, _records}
      end
    end

    for {name, content, reason, error_code} <- [
          {"content that is not JSON", "{", :invalid_json, "INVALID_JSON"},
          {"content that is not a stored response", ~s({"meta": {}, "body": {}}),
           :schema_mismatch, "SCHEMA_MISMATCH"}
        ] do
      test "returns a permanent parse failure for #{name}" do
        %{destination: destination} = stored()

        assert process(destination, unquote(content)) ==
                 {:error,
                  %{
                    stage: :parse,
                    reason: unquote(reason),
                    error_code: unquote(error_code),
                    class: :permanent
                  }}

        refute_received {:published, _records}
      end
    end

    test "returns a permanent parse failure for content read from another destination" do
      %{destination: destination, content: content} = stored()
      other = String.replace(destination, "dt=2026-10-05", "dt=2026-10-06")

      assert {:error, %{stage: :parse, reason: :destination_mismatch, class: :permanent}} =
               process(other, content)
    end

    for {name, reason, class} <- [
          {"a publisher that is unavailable", :unavailable, :transient},
          {"a record too large", :record_too_large, :permanent}
        ] do
      test "returns a publish failure for #{name}" do
        %{destination: destination, content: content} = stored()

        assert process(destination, content, {:error, unquote(reason)}) ==
                 {:error,
                  %{
                    stage: :publish_routes,
                    reason: unquote(reason),
                    error_code: "WRITE_FAILURE",
                    class: unquote(class)
                  }}
      end
    end

    test "logs nothing for a failure" do
      %{destination: destination} = stored()

      assert capture_log(fn -> process(destination, "{") end) == ""
    end
  end
end
