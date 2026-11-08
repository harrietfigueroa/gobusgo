defmodule Gobusgo.Routing.Snapshot do
  @prefix "routing/snapshots"
  @chunk_s 3_600

  @moduledoc """
  One routing snapshot as the files that hold it and the manifest entry that
  names them. Everything here is pure, so a snapshot is a function of its
  timetable, its walking links, and the time it was built.

  The connections are split into chunks by the hour of their departure, so
  a reader fetches from the hour of its query onward and stops once a chunk
  departs after the best arrival it has found (decided in GOB-237). The
  stop, trip, and transfer tables are files of their own.

  A file's name is its kind and the SHA-256 of its content, and it is stored
  at `#{@prefix}/dt=<build date>/<name>`, so a file's address never holds
  other content and is cached as immutable. A build on another day writes
  its files again under that day.
  """

  alias Gobusgo.Routing.SnapshotFormat
  alias Gobusgo.Routing.Timetable
  alias Gobusgo.Routing.Transfers

  @type file :: %{destination: String.t(), content: binary()}

  @doc "The prefix of every snapshot file's destination, without a trailing `/`."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The seconds of departure one chunk of connections spans."
  @spec chunk_s() :: pos_integer()
  def chunk_s, do: @chunk_s

  @doc """
  Returns the files of the snapshot of `input.timetable` with
  `input.walking_links`, built at `input.built_at` from fetches made from
  `input.fetched_at_oldest` to `input.fetched_at_newest`, and its manifest
  entry.
  """
  @spec build(%{
          timetable: Timetable.t(),
          walking_links: [SnapshotFormat.transfer()],
          built_at: DateTime.t(),
          fetched_at_oldest: DateTime.t(),
          fetched_at_newest: DateTime.t()
        }) :: %{files: [file()], entry: map()}
  def build(
        %{timetable: timetable, walking_links: walking_links, built_at: %DateTime{} = built_at} =
          input
      ) do
    directory = "#{@prefix}/dt=#{built_at |> DateTime.to_date() |> Date.to_iso8601()}"
    stops = file(directory, :stops, timetable.stop_ids)
    trips = file(directory, :trips, timetable.trips)
    transfers = file(directory, :transfers, walking_links)

    chunks =
      timetable.connections
      |> Enum.chunk_by(&Integer.floor_div(&1.departure_s, @chunk_s))
      |> Enum.map(fn [first | _rest] = connections ->
        %{
          file: file(directory, :connections, connections),
          departure_s_min: first.departure_s,
          departure_s_max: List.last(connections).departure_s,
          count: length(connections)
        }
      end)

    entry = %{
      "serviceDate" => Date.to_iso8601(timetable.service_date),
      "serviceDayStartMs" => timetable.service_day_start_ms,
      "previousServiceDateIncluded" => timetable.previous_date_included,
      "builtAt" => DateTime.to_iso8601(built_at),
      "sourceFetchedAt" => %{
        "oldest" => DateTime.to_iso8601(input.fetched_at_oldest),
        "newest" => DateTime.to_iso8601(input.fetched_at_newest)
      },
      "routeCount" => timetable.route_count,
      "stopCount" => length(timetable.stop_ids),
      "tripCount" => length(timetable.trips),
      "connectionCount" => length(timetable.connections),
      "transferRules" => transfer_rules(),
      "walkingLinkCount" => length(walking_links),
      "files" => %{
        "stops" => file_entry(stops),
        "trips" => file_entry(trips),
        "transfers" => file_entry(transfers)
      },
      "connectionChunks" =>
        for chunk <- chunks do
          chunk.file
          |> file_entry()
          |> Map.merge(%{
            "departureSMin" => chunk.departure_s_min,
            "departureSMax" => chunk.departure_s_max,
            "count" => chunk.count
          })
        end
    }

    %{files: [stops, trips, transfers | Enum.map(chunks, & &1.file)], entry: entry}
  end

  defp transfer_rules do
    rules = Transfers.rules()

    %{
      "minimumTransferS" => rules.minimum_transfer_s,
      "walkRadiusM" => rules.walk_radius_m,
      "walkSpeedMPerS" => rules.walk_speed_m_per_s
    }
  end

  defp file(directory, kind, records) do
    content = SnapshotFormat.encode(kind, records)
    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    %{destination: "#{directory}/#{kind}-#{sha256}.bin", content: content, sha256: sha256}
  end

  defp file_entry(%{destination: destination, content: content, sha256: sha256}) do
    %{"path" => "/" <> destination, "byteSize" => byte_size(content), "sha256" => sha256}
  end
end
