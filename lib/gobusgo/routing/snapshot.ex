defmodule Gobusgo.Routing.Snapshot do
  @prefix "routing/snapshots"
  @chunk_s 3_600
  @microdegrees_per_degree 1_000_000

  @moduledoc """
  One routing snapshot as the files that hold it and the manifest entry that
  names them. Everything here is pure, so a snapshot is a function of its
  timetable, its walking links, and the time it was built.

  The connections are split into chunks by the hour of their departure, so
  a reader fetches from the hour of its query onward and stops once a chunk
  departs after the best arrival it has found (decided in GOB-237). The
  stop, trip, transfer, and position tables are files of their own.

  A file's name is its kind and the SHA-256 of its content, and it is stored
  at `#{@prefix}/dt=<build date>/<name>`, so a file's address never holds
  other content and is cached as immutable. A build on another day writes
  its files again under that day.
  """

  alias Gobusgo.Assert
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
  `input.walking_links` and `input.positions`, the position of each stop by
  identifier, built at `input.built_at` from fetches made from
  `input.fetched_at_oldest` to `input.fetched_at_newest`, and its manifest
  entry. A stop `input.positions` leaves out has an unknown position.
  """
  @spec build(%{
          timetable: Timetable.t(),
          walking_links: [SnapshotFormat.transfer()],
          positions: %{String.t() => Transfers.position()},
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

    positions =
      file(directory, :positions, position_records(timetable.stop_ids, input.positions))

    chunks =
      for {first_index, last_index} <- chunk_ranges(timetable) do
        record_bytes = SnapshotFormat.connection_bytes()
        count = last_index - first_index + 1

        body =
          binary_part(timetable.connections, first_index * record_bytes, count * record_bytes)

        %{
          file: packed_file(directory, :connections, body),
          departure_s_min:
            SnapshotFormat.connection_departure_s(timetable.connections, first_index),
          departure_s_max:
            SnapshotFormat.connection_departure_s(timetable.connections, last_index),
          count: count
        }
      end

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
      "connectionCount" => timetable.connection_count,
      "transferRules" => transfer_rules(),
      "walkingLinkCount" => length(walking_links),
      "files" => %{
        "stops" => file_entry(stops),
        "trips" => file_entry(trips),
        "transfers" => file_entry(transfers),
        "positions" => file_entry(positions)
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

    %{files: [stops, trips, transfers, positions | Enum.map(chunks, & &1.file)], entry: entry}
  end

  defp position_records(stop_ids, positions) do
    for stop_id <- stop_ids do
      case Map.get(positions, stop_id) do
        %{lat: lat, lon: lon} ->
          %{lat_microdegrees: microdegrees(lat), lon_microdegrees: microdegrees(lon)}

        nil ->
          :unknown
      end
    end
  end

  defp microdegrees(degrees), do: round(degrees * @microdegrees_per_degree)

  defp transfer_rules do
    rules = Transfers.rules()

    %{
      "minimumTransferS" => rules.minimum_transfer_s,
      "walkRadiusM" => rules.walk_radius_m,
      "walkSpeedMPerS" => rules.walk_speed_m_per_s,
      "walkLinkCountPerStopMax" => rules.link_count_per_stop_max
    }
  end

  # The first and last index of each run of connections departing in one
  # chunk's span, in order. The connections are in departure order, so a run
  # ends where the next connection departs in a later span.
  defp chunk_ranges(%{connections: connections, connection_count: connection_count}) do
    Assert.condition(
      byte_size(connections) == connection_count * SnapshotFormat.connection_bytes(),
      "the timetable must hold #{connection_count} connection records"
    )

    {ranges, _span} =
      Enum.reduce(0..(connection_count - 1)//1, {[], nil}, fn index, {ranges, span} ->
        index_span =
          Integer.floor_div(SnapshotFormat.connection_departure_s(connections, index), @chunk_s)

        case {index_span, ranges} do
          {^span, [{first_index, _last_index} | rest]} -> {[{first_index, index} | rest], span}
          {_other, _ranges} -> {[{index, index} | ranges], index_span}
        end
      end)

    Enum.reverse(ranges)
  end

  defp file(directory, kind, records) do
    content_file(directory, kind, SnapshotFormat.encode(kind, records))
  end

  defp packed_file(directory, kind, body) do
    content_file(directory, kind, SnapshotFormat.encode_packed(kind, body))
  end

  defp content_file(directory, kind, content) do
    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    %{destination: "#{directory}/#{kind}-#{sha256}.bin", content: content, sha256: sha256}
  end

  defp file_entry(%{destination: destination, content: content, sha256: sha256}) do
    %{"path" => "/" <> destination, "byteSize" => byte_size(content), "sha256" => sha256}
  end
end
