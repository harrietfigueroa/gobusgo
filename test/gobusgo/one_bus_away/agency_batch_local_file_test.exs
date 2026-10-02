defmodule Gobusgo.OneBusAway.AgencyBatchLocalFileTest do
  # Runs process/2 against the local file backends in a temporary directory:
  # stored responses are written through the writer, the batch reads them back
  # through the reader, and the published output is read from the same
  # directory.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Reader
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @window %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
  @trigger_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"

  setup %{tmp_dir: tmp_dir} do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()

    for {fetched_at, request_id} <- [
          {~U[2026-10-02 03:15:00Z], "0199c4a2-7e1b-7a3f-9d20-000000000001"},
          {~U[2026-10-02 03:16:00Z], "0199c4a2-7e1b-7a3f-9d20-000000000002"}
        ] do
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
    end

    options = [
      read_options: [base_dir: tmp_dir],
      write_options: [base_dir: tmp_dir],
      clock: fn -> ~U[2026-10-03 00:05:00Z] end
    ]

    %{options: options, request: %{window: @window, trigger_id: @trigger_id, reprocess: false}}
  end

  test "publishes one readable output from the stored responses", %{
    tmp_dir: tmp_dir,
    options: options,
    request: request
  } do
    assert {:ok, %{outcome: :published, destination: destination, input_count: 2}} =
             AgencyBatch.process(request, options)

    assert {:ok, content} = Reader.read(destination, base_dir: tmp_dir)
    assert %{"agencies" => agencies, "meta" => meta} = JSON.decode!(content)
    assert Enum.map(agencies, & &1["id"]) == ["1", "40"]
    assert meta["schemaVersion"] == 1
    assert Enum.map(meta["inputs"], & &1["duplicate"]) == [false, true]
  end

  test "returns already_published for a second run of the window", %{
    options: options,
    request: request
  } do
    assert {:ok, %{outcome: :published, destination: destination}} =
             AgencyBatch.process(request, options)

    assert {:ok, %{outcome: :already_published, destination: ^destination}} =
             AgencyBatch.process(request, options)
  end

  test "returns the writer's already_exists for a reprocess in the same second", %{
    options: options,
    request: request
  } do
    assert {:ok, %{outcome: :published}} = AgencyBatch.process(request, options)

    assert AgencyBatch.process(%{request | reprocess: true}, options) ==
             {:error, {:write, :already_exists}}
  end
end
