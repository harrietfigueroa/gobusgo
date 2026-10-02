defmodule Gobusgo.OneBusAway.AgencyBatchLocalFileTest do
  # Runs the event-driven flow against the local file backends in a temporary
  # directory: stored responses are written through the writer, reconciliation
  # finds them and publishes one event each, and the processor reads the file
  # each event names. A publisher double defined here collects the records.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.Reconciliation
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      :ok
    end
  end

  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @request_ids ["0199c4a2-7e1b-7a3f-9d20-000000000001", "0199c4a2-7e1b-7a3f-9d20-000000000002"]

  setup %{tmp_dir: tmp_dir} do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()

    destinations =
      for {fetched_at, request_id} <-
            Enum.zip([~U[2026-10-02 03:15:00Z], ~U[2026-10-02 03:16:00Z]], @request_ids) do
        response = %{
          agencies: [],
          envelope: envelope,
          fetched_at: fetched_at,
          host: "oba.example.test",
          http_status: 200,
          method: "GET"
        }

        stored = RawAgencyResponse.build(%{response: response, request_id: request_id})
        :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: tmp_dir)
        stored.destination
      end

    options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [backend: RecordingPublisher, recipient: self()]
    ]

    %{options: options, destinations: destinations}
  end

  defp published do
    assert_received {:published, records}
    records
  end

  test "publishes the agencies and the manifest of a stored response", %{
    options: options,
    destinations: [destination | _rest]
  } do
    assert {:ok, %{agency_count: 2, request_id: request_id}} =
             AgencyBatch.process(destination, options)

    assert request_id == hd(@request_ids)
    assert Enum.map(published(), & &1.key) == ["agency/1", "agency/40"]
    assert [%{key: "manifest"}] = published()
  end

  test "processes every file a reconciliation of the day names", %{
    options: options,
    destinations: destinations
  } do
    request = %{
      dataset: "oba/agencies-with-coverage",
      range: %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
    }

    assert Reconciliation.republish(request, options) ==
             {:ok, %{published_count: 2, skipped: []}}

    named = Enum.map(published(), &JSON.decode!(&1.value)["data"]["destination"])
    assert named == destinations

    for destination <- named do
      assert {:ok, %{destination: ^destination}} = AgencyBatch.process(destination, options)
    end
  end

  test "returns a permanent read failure for a destination that holds nothing", %{
    options: options
  } do
    missing = "raw/oba/agencies-with-coverage/dt=2026-10-02/missing.json"

    assert AgencyBatch.process(missing, options) ==
             {:error,
              %{class: :permanent, error_code: "READ_FAILURE", stage: :read, reason: :not_found}}
  end

  test "returns a permanent read failure for a destination outside the storage", %{
    options: options
  } do
    assert {:error,
            %{
              class: :permanent,
              error_code: "READ_FAILURE",
              stage: :read,
              reason: {:invalid_destination, _rule}
            }} = AgencyBatch.process("../outside.json", options)
  end
end
