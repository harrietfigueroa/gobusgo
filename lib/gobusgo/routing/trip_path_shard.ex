defmodule Gobusgo.Routing.TripPathShard do
  @kind 1
  @version 1
  @section_count 4
  @build_trip_count_max 100
  @latitude_e5_max 9_000_000
  @longitude_e5_max 18_000_000
  @u32_max 4_294_967_295

  @moduledoc """
  The trip path shard, kind #{@kind} of the packed container: every trip of
  one route on one service date that has a path, the path of
  `Gobusgo.OneBusAway.TripPath` in a form a reader decodes a trip at a
  time. The shard names no route and no service date, so the same schedule
  and route path give the same bytes on any date, and the trip path index
  of `Gobusgo.Routing.TripPathIndex` names the route. Everything here is
  pure; `lib/gobusgo/routing/AGENTS.md` holds the format.

  A geometry is a distinct sequence of points in the polyline's own unit,
  1e-5 degrees, a pattern is a geometry with
  the distance of each stop along it, and a trip is a pattern with its own
  stop times. Two stop sequences that follow one polyline share a
  geometry, and two that also stand at the same distances share a pattern.
  Section 1 holds the geometries, section 2 the patterns, section 3 one
  `u32` column of three blocks of one value per trip, in trip identifier
  order: the identifier's string index, the pattern index, and the byte
  offset of the trip's times in section 4. Section 4 holds the times.
  """

  @behaviour Gobusgo.Packed.Kind

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.StringTable
  alias Gobusgo.Packed.Varint
  alias Gobusgo.Polyline

  @typedoc "One stop time of a trip, as `Gobusgo.OneBusAway.CompactSchedule.stop_times/2` returns it."
  @type stop_time :: TripPath.stop_time()

  @typedoc "A trip decoded: its path in 1e-5 degrees and its stops' distances and times."
  @type decoded_trip :: %{
          id: String.t(),
          points: [{integer(), integer()}],
          stops: [%{distance_m: integer(), arrival_s: integer(), departure_s: integer()}]
        }

  @typedoc "What `decode/1` refuses a shard for, on top of the container's refusals."
  @type refusal :: Packed.refusal() | :bad_index

  @doc "The kind number of a trip path shard."
  @spec kind() :: pos_integer()
  def kind, do: @kind

  @doc "The versions of the shard this module reads."
  @spec versions() :: [pos_integer()]
  def versions, do: [@version]

  @doc """
  Returns the shard of `input.trips`, trips of one route each with its
  `stop_times`, over the route's `input.polylines` and `input.stop_positions`,
  by stop identifier: `{:ok, built}` with the expanded `content` and the
  counts of trips, patterns, and geometries it holds, or `:no_paths` when
  no trip has a path. A trip any of whose stops has no position has none and
  is left out, and so is a trip whose identifier an earlier trip has.
  """
  @spec build(%{
          polylines: [String.t()],
          stop_positions: %{String.t() => TripPath.position()},
          trips: [%{id: String.t(), stop_times: [stop_time()]}]
        }) ::
          {:ok,
           %{
             content: binary(),
             trip_count: pos_integer(),
             pattern_count: pos_integer(),
             geometry_count: pos_integer()
           }}
          | :no_paths
  def build(%{polylines: polylines, stop_positions: stop_positions, trips: trips} = input)
      when is_list(polylines) and is_map(stop_positions) and is_list(trips) do
    ordered =
      trips
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&{stop_sequence(&1), &1})

    paths = sequence_paths(input, ordered)

    initial = %{
      strings: StringTable.new(),
      geometry_of_points: %{},
      geometries: [],
      pattern_of_key: %{},
      patterns: [],
      pattern_of_sequence: %{},
      rows: [],
      times: [],
      times_bytes: 0
    }

    state = Enum.reduce(ordered, initial, &add_trip(&1, &2, paths))

    case state.rows do
      [] -> :no_paths
      _rows -> {:ok, encoded(state)}
    end
  end

  defp stop_sequence(%{stop_times: stop_times}), do: Enum.map(stop_times, & &1.stop_id)

  # The path of each stop sequence the trips serve, `ordered` as pairs of
  # sequence and trip, built once from the first trip to serve it, in batches
  # of the most trips one build takes.
  defp sequence_paths(input, ordered) do
    firsts =
      ordered
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.chunk_every(@build_trip_count_max)

    for batch <- firsts, reduce: %{} do
      paths ->
        built =
          TripPath.build_route(%{
            polylines: input.polylines,
            stop_positions: input.stop_positions,
            trips: Enum.map(batch, &elem(&1, 1))
          })

        for {sequence, trip} <- batch, into: paths do
          {sequence, Map.fetch!(built.paths, trip.id)}
        end
    end
  end

  defp add_trip({sequence, trip}, state, paths) do
    case Map.fetch!(paths, sequence) do
      {:ok, path} ->
        {pattern_index, state} = pattern_of(sequence, path, state)
        append_trip(trip, pattern_index, state)

      {:error, _reason} ->
        state
    end
  end

  defp pattern_of(sequence, path, state) do
    case Map.fetch(state.pattern_of_sequence, sequence) do
      {:ok, pattern_index} ->
        {pattern_index, state}

      :error ->
        {geometry_index, state} = geometry_of(path, state)
        steps = distance_steps(path)
        {pattern_index, state} = pattern_of_key({geometry_index, steps}, state)
        {pattern_index, put_in(state.pattern_of_sequence[sequence], pattern_index)}
    end
  end

  defp geometry_of(%{points: points}, state) do
    case Map.fetch(state.geometry_of_points, points) do
      {:ok, geometry_index} ->
        {geometry_index, state}

      :error ->
        geometry_index = map_size(state.geometry_of_points)
        geometry = encode_geometry(points)

        {geometry_index,
         %{
           state
           | geometry_of_points: Map.put(state.geometry_of_points, points, geometry_index),
             geometries: [geometry | state.geometries]
         }}
    end
  end

  defp pattern_of_key({geometry_index, steps} = key, state) do
    case Map.fetch(state.pattern_of_key, key) do
      {:ok, pattern_index} ->
        {pattern_index, state}

      :error ->
        pattern_index = map_size(state.pattern_of_key)

        pattern = [
          Varint.encode(geometry_index),
          Varint.encode(length(steps)),
          for(step <- steps, do: Varint.encode(Varint.zigzag(step)))
        ]

        {pattern_index,
         %{
           state
           | pattern_of_key: Map.put(state.pattern_of_key, key, pattern_index),
             patterns: [pattern | state.patterns]
         }}
    end
  end

  defp append_trip(%{id: trip_id, stop_times: stop_times}, pattern_index, state) do
    {string_index, strings} = StringTable.intern(state.strings, trip_id)
    times = times(stop_times)
    times_bytes = IO.iodata_length(times)

    Assert.condition(
      state.times_bytes + times_bytes <= @u32_max,
      "the times of a shard must fit 32 bits, got: #{state.times_bytes + times_bytes}"
    )

    %{
      state
      | strings: strings,
        rows: [{string_index, pattern_index, state.times_bytes} | state.rows],
        times: [times | state.times],
        times_bytes: state.times_bytes + times_bytes
    }
  end

  # Per stop, the zigzag varints of the arrival since the stop before's
  # arrival, the first from zero, and of the departure after the arrival.
  defp times(stop_times) do
    {encoded, _arrival_s} =
      Enum.map_reduce(stop_times, 0, fn %{arrival_s: arrival_s, departure_s: departure_s},
                                        arrival_s_before ->
        {[
           Varint.encode(Varint.zigzag(arrival_s - arrival_s_before)),
           Varint.encode(Varint.zigzag(departure_s - arrival_s))
         ], arrival_s}
      end)

    encoded
  end

  # A geometry is a varint count of points, then the zigzag varint latitude
  # and longitude steps of each, the first from (0, 0): the integers the
  # encoded polyline holds, with no change of unit, since every coordinate is
  # a whole number of 1e-5 degrees and a finer unit only adds bits.
  defp encode_geometry(encoded_points) do
    {:ok, steps} = Polyline.decode_integers(encoded_points)
    Assert.condition(rem(length(steps), 2) == 0, "a point holds a latitude and a longitude")

    [
      Varint.encode(div(length(steps), 2)),
      for(step <- steps, do: Varint.encode(Varint.zigzag(step)))
    ]
  end

  # The distance since the stop before in meters of each stop, the first
  # from zero, which every third number of the path's stops holds.
  defp distance_steps(%{stops: stops}) do
    {:ok, numbers} = Polyline.decode_integers(stops)
    numbers |> Enum.chunk_every(3) |> Enum.map(&hd/1)
  end

  defp encoded(state) do
    rows = Enum.reverse(state.rows)
    trip_count = length(rows)
    geometries = Enum.reverse(state.geometries)
    patterns = Enum.reverse(state.patterns)

    columns =
      Columns.encode(
        :u32,
        Enum.map(rows, &elem(&1, 0)) ++
          Enum.map(rows, &elem(&1, 1)) ++ Enum.map(rows, &elem(&1, 2))
      )

    content =
      Packed.encode(%{
        kind: @kind,
        version: @version,
        record_count: trip_count,
        strings: StringTable.strings(state.strings),
        sections: [
          [Varint.encode(length(geometries)), geometries],
          [Varint.encode(length(patterns)), patterns],
          columns,
          Enum.reverse(state.times)
        ]
      })

    %{
      content: content,
      trip_count: trip_count,
      pattern_count: length(patterns),
      geometry_count: length(geometries)
    }
  end

  @doc """
  Returns the trips the shard `binary`, an expanded container, holds, in
  identifier order, or the first rule it breaks.
  """
  @spec decode(binary()) :: {:ok, [decoded_trip()]} | {:error, refusal()}
  def decode(binary) when is_binary(binary) do
    expectation = %{kind: @kind, versions: [@version], section_count: @section_count}

    with {:ok, decoded} <- Packed.decode(binary, expectation) do
      trips(decoded)
    end
  end

  defp trips(%{record_count: count, strings: strings, sections: sections}) do
    [geometry_section, pattern_section, trip_section, times_section] = sections

    with {:ok, geometries} <- decode_geometries(geometry_section),
         {:ok, patterns} <- decode_patterns(pattern_section, tuple_size(geometries)),
         {:ok, columns} <- Columns.decode(:u32, trip_section, count * 3) do
      {string_indexes, rest} = Enum.split(columns, count)
      {pattern_indexes, offsets} = Enum.split(rest, count)

      decode_trips(
        %{
          rows: Enum.zip([string_indexes, pattern_indexes, offsets]),
          strings: strings,
          geometries: geometries,
          patterns: patterns
        },
        times_section
      )
    end
  end

  defp decode_geometries(section) do
    with {:ok, count, rest} <- Varint.decode(section),
         {:ok, geometries, <<>>} <- decode_each(rest, count, &decode_geometry/1),
         false <- Enum.member?(geometries, []) do
      {:ok, List.to_tuple(geometries)}
    else
      true -> {:error, :bad_index}
      {:ok, _geometries, _rest} -> {:error, :bad_section_size}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp decode_geometry(binary) do
    with {:ok, count, rest} <- Varint.decode(binary) do
      if count * 2 <= byte_size(rest) do
        decode_points(rest, count, {0, 0}, [])
      else
        {:error, :truncated}
      end
    end
  end

  defp decode_points(rest, 0, _last, points), do: {:ok, Enum.reverse(points), rest}

  defp decode_points(binary, remaining, {latitude, longitude}, points) do
    with {:ok, latitude_zigzag, after_latitude} <- Varint.decode(binary),
         {:ok, longitude_zigzag, after_longitude} <- Varint.decode(after_latitude) do
      point =
        {latitude + Varint.unzigzag(latitude_zigzag),
         longitude + Varint.unzigzag(longitude_zigzag)}

      if abs(elem(point, 0)) <= @latitude_e5_max and abs(elem(point, 1)) <= @longitude_e5_max do
        decode_points(after_longitude, remaining - 1, point, [point | points])
      else
        {:error, :bad_position}
      end
    end
  end

  defp decode_patterns(section, geometry_count) do
    with {:ok, count, rest} <- Varint.decode(section),
         {:ok, patterns, <<>>} <- decode_each(rest, count, &decode_pattern/1) do
      if Enum.all?(patterns, &pattern_valid?(&1, geometry_count)) do
        {:ok, List.to_tuple(patterns)}
      else
        {:error, :bad_index}
      end
    else
      {:ok, _patterns, _rest} -> {:error, :bad_section_size}
      {:error, _reason} = refusal -> refusal
    end
  end

  # A pattern names a geometry the shard holds, has a stop, and has no stop
  # before the stop before it.
  defp pattern_valid?({geometry_index, steps}, geometry_count) do
    is_geometry_held = geometry_index < geometry_count
    is_stop_held = steps != []
    is_ordered = Enum.all?(steps, &(&1 >= 0))
    is_geometry_held and is_stop_held and is_ordered
  end

  defp decode_pattern(binary) do
    with {:ok, geometry_index, rest} <- Varint.decode(binary),
         {:ok, stop_count, rest} <- Varint.decode(rest),
         {:ok, zigzags, rest} <- decode_each(rest, stop_count, &Varint.decode/1) do
      {:ok, {geometry_index, Enum.map(zigzags, &Varint.unzigzag/1)}, rest}
    end
  end

  # Each item takes at least one byte, so a count the bytes cannot hold is
  # refused before the loop.
  defp decode_each(binary, count, decoder) do
    if count <= byte_size(binary) do
      decode_each(binary, count, decoder, [])
    else
      {:error, :truncated}
    end
  end

  defp decode_each(binary, 0, _decoder, items), do: {:ok, Enum.reverse(items), binary}

  defp decode_each(binary, remaining, decoder, items) do
    with {:ok, item, rest} <- decoder.(binary) do
      decode_each(rest, remaining - 1, decoder, [item | items])
    end
  end

  defp decode_trips(shard, times_section) do
    initial = {:ok, [], 0}

    result =
      Enum.reduce_while(shard.rows, initial, fn row, {:ok, trips, offset} ->
        case decode_trip(row, offset, shard, times_section) do
          {:ok, trip, next_offset} -> {:cont, {:ok, [trip | trips], next_offset}}
          {:error, _reason} = refusal -> {:halt, refusal}
        end
      end)

    case result do
      {:ok, trips, offset} when offset == byte_size(times_section) -> distinct(trips)
      {:ok, _trips, _offset} -> {:error, :bad_section_size}
      {:error, _reason} = refusal -> refusal
    end
  end

  # A trip identifier names one trip of a shard.
  defp distinct(reversed_trips) do
    trips = Enum.reverse(reversed_trips)

    if length(Enum.uniq_by(trips, & &1.id)) == length(trips) do
      {:ok, trips}
    else
      {:error, :bad_index}
    end
  end

  defp decode_trip({string_index, pattern_index, offset}, offset, shard, times_section)
       when string_index < tuple_size(shard.strings) and
              pattern_index < tuple_size(shard.patterns) do
    {geometry_index, steps} = elem(shard.patterns, pattern_index)
    rest = binary_part(times_section, offset, byte_size(times_section) - offset)

    with {:ok, pairs, after_times} <-
           decode_each(rest, length(steps), &decode_time_pair/1) do
      trip = %{
        id: elem(shard.strings, string_index),
        points: elem(shard.geometries, geometry_index),
        stops: stops(steps, pairs)
      }

      {:ok, trip, byte_size(times_section) - byte_size(after_times)}
    end
  end

  defp decode_trip(_row, _offset, _shard, _times_section), do: {:error, :bad_index}

  defp decode_time_pair(binary) do
    with {:ok, arrival_zigzag, rest} <- Varint.decode(binary),
         {:ok, dwell_zigzag, rest} <- Varint.decode(rest) do
      {:ok, {Varint.unzigzag(arrival_zigzag), Varint.unzigzag(dwell_zigzag)}, rest}
    end
  end

  defp stops(steps, pairs) do
    {stops, _before} =
      steps
      |> Enum.zip(pairs)
      |> Enum.map_reduce({0, 0}, fn {distance_step_m, {arrival_step_s, dwell_s}},
                                    {distance_m_before, arrival_s_before} ->
        distance_m = distance_m_before + distance_step_m
        arrival_s = arrival_s_before + arrival_step_s

        {%{distance_m: distance_m, arrival_s: arrival_s, departure_s: arrival_s + dwell_s},
         {distance_m, arrival_s}}
      end)

    stops
  end

  @impl Gobusgo.Packed.Kind
  def inspect(decoded) do
    {:ok, trips} = trips(decoded)

    %{
      "kind" => "trip path shard",
      "version" => decoded.version,
      "trips" =>
        for trip <- trips do
          %{
            "id" => trip.id,
            "pointCount" => length(trip.points),
            "stops" =>
              for stop <- trip.stops do
                %{
                  "distanceM" => stop.distance_m,
                  "arrivalS" => stop.arrival_s,
                  "departureS" => stop.departure_s
                }
              end
          }
        end
    }
  end
end
