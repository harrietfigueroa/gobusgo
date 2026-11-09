defmodule Gobusgo.Routing.SnapshotTest do
  # Verifies the files and the manifest entry of a snapshot as a pure
  # function of a timetable written out by hand.
  use ExUnit.Case, async: true

  alias Gobusgo.Routing.Snapshot
  alias Gobusgo.Routing.SnapshotFormat

  defp connection(departure_s) do
    %{
      departure_s: departure_s,
      arrival_s: departure_s + 60,
      departure_stop: 0,
      arrival_stop: 1,
      trip: 0,
      sequence: 0,
      boarding: true,
      alighting: true
    }
  end

  defp build(connections) do
    Snapshot.build(%{
      timetable: %{
        service_date: ~D[2026-11-08],
        service_day_start_ms: 1_794_124_800_000,
        previous_date_included: true,
        route_count: 1,
        stop_ids: ["1_A", "1_B"],
        trips: [%{id: "t", route_id: "1_R", service_day_offset: 0}],
        connections:
          for(
            connection <- connections,
            into: <<>>,
            do: SnapshotFormat.encode_connection(connection)
          ),
        connection_count: length(connections)
      },
      walking_links: [],
      positions: %{"1_A" => %{lat: 47.6080131, lon: -122.3351669}},
      built_at: ~U[2026-11-08 12:00:00Z],
      fetched_at_oldest: ~U[2026-11-07 01:00:00Z],
      fetched_at_newest: ~U[2026-11-08 02:00:00Z]
    })
  end

  test "splits the connections into chunks by the hour of their departure" do
    %{entry: entry} =
      build([connection(100), connection(3_599), connection(3_600), connection(90_000)])

    assert Enum.map(
             entry["connectionChunks"],
             &{&1["departureSMin"], &1["departureSMax"], &1["count"]}
           ) ==
             [{100, 3_599, 2}, {3_600, 3_600, 1}, {90_000, 90_000, 1}]
  end

  test "names each file by its kind and the SHA-256 of its content, under the build date" do
    %{files: files} = build([connection(100)])

    for %{destination: destination, content: content} <- files do
      sha256 = Base.encode16(:crypto.hash(:sha256, content), case: :lower)

      assert destination =~
               ~r{^routing/snapshots/dt=2026-11-08/(stops|trips|transfers|positions|connections)-#{sha256}\.bin$}
    end
  end

  test "points the entry at each file it writes" do
    %{files: files, entry: entry} = build([connection(100)])

    paths = [
      entry["files"]["stops"],
      entry["files"]["trips"],
      entry["files"]["transfers"],
      entry["files"]["positions"] | entry["connectionChunks"]
    ]

    assert Enum.map(paths, & &1["path"]) == Enum.map(files, &("/" <> &1.destination))
    assert Enum.map(paths, & &1["byteSize"]) == Enum.map(files, &byte_size(&1.content))
  end

  test "writes each stop's position in stop order, unknown for a stop with none" do
    %{files: files, entry: entry} = build([connection(100)])
    path = entry["files"]["positions"]["path"]
    %{content: content} = Enum.find(files, &("/" <> &1.destination == path))

    assert SnapshotFormat.decode(content) ==
             {:ok,
              %{
                kind: :positions,
                records: [
                  %{lat_microdegrees: 47_608_013, lon_microdegrees: -122_335_167},
                  :unknown
                ]
              }}
  end

  test "writes files the format decodes" do
    %{files: files} = build([connection(100)])

    for %{content: content} <- files do
      assert {:ok, _decoded} = SnapshotFormat.decode(content)
    end
  end

  test "states the coverage, the day start, the freshness, and the transfer rules" do
    %{entry: entry} = build([connection(100)])

    assert %{
             "serviceDate" => "2026-11-08",
             "serviceDayStartMs" => 1_794_124_800_000,
             "previousServiceDateIncluded" => true,
             "sourceFetchedAt" => %{
               "oldest" => "2026-11-07T01:00:00Z",
               "newest" => "2026-11-08T02:00:00Z"
             },
             "transferRules" => %{
               "minimumTransferS" => 120,
               "walkRadiusM" => 400,
               "walkSpeedMPerS" => 1.2,
               "walkLinkCountPerStopMax" => 64
             }
           } = entry
  end
end
