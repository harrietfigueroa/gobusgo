defmodule Gobusgo.Routing.WalkLinks do
  @street_meters_max 600
  @link_count_per_stop_max 64
  @shard_byte_max 16 * 1_024 * 1_024
  @read_concurrency 8
  @read_timeout_ms 60_000
  @cell_rows 2
  @cell_columns 2
  @margin_meters 700
  @child_heap_words_max_default 24_000_000
  @receive_timeout_max_ms 4_294_967_295

  @moduledoc """
  The walking links of a snapshot measured along the walk graph's streets.
  Everything here is pure but the reads of the shards, which the caller
  hands in as a function and which run at most #{@read_concurrency} at a
  time.

  A stop's links are the stops within the walking radius of it in a straight
  line whose street is at most #{@street_meters_max} m, nearest street first,
  at most #{@link_count_per_stop_max}. A pair that is disconnected on the
  graph has no link. A pair with an end farther than the snap bound from
  every street keeps its straight-line distance, the walk a page would draw
  as a straight line.

  A table holds, for each stop, its position and its links, as a map from the
  identifier of each stop it links to its street meters, and the identifier
  of the graph build it was measured on. `stale_stop_ids/1` names the stops a
  table has to measure again for the positions now held: a stop that is new
  or moved or measured on another build, and each stop within the radius of
  one that moved, appeared, or left.

  `compute/1` measures those stops tile by tile, in a process of its own for
  each tile, which returns its stops' links packed: a tile is
  #{@cell_rows} by #{@cell_columns} cells, and a cell's stops share one graph
  of the pieces within #{@margin_meters} m of the cell, out of the 3 by 3
  tiles around its tile, on a plane tangent at the cell's middle, with one
  search for each stop. The caller keeps the shards as the binaries it read,
  off its heap, up to #{@shard_byte_max} bytes, and a tile's process decodes
  them, so no heap holds the decoded shards of more than one tile.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Routing.SnapshotFormat
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Search
  alias Gobusgo.WalkGraph.Tiles

  @radius_meters Transfers.rules().walk_radius_m
  @units_per_degree Format.units_per_degree()

  @type position :: %{lat: number(), lon: number()}
  @type positions :: %{String.t() => position()}
  @type table :: %{
          build_id: String.t(),
          stops: %{String.t() => %{lat: number(), lon: number(), links: [{String.t(), float()}]}}
        }
  @type stats :: %{
          stop_count: non_neg_integer(),
          measured_stop_count: non_neg_integer(),
          link_count: non_neg_integer(),
          straight_link_count: non_neg_integer(),
          dropped_link_count: non_neg_integer(),
          read_count: non_neg_integer()
        }
  @type load_result :: {:ok, binary()} | {:error, :corrupt | {:io, term()}}

  @doc "The longest street, in meters, that a link may have."
  @spec street_meters_max() :: pos_integer()
  def street_meters_max, do: @street_meters_max

  @doc "The most bytes of shards kept between tiles."
  @spec shard_byte_max() :: pos_integer()
  def shard_byte_max, do: @shard_byte_max

  @doc "The identifier of what a table is measured over: the graph build and every position."
  @spec key(%{build_id: String.t(), positions: positions()}) :: binary()
  def key(%{build_id: build_id, positions: positions}) do
    stops =
      positions |> Enum.map(fn {id, %{lat: lat, lon: lon}} -> {id, lat, lon} end) |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({build_id, stops}))
  end

  @doc "The table as one binary, which a process keeps off its heap and hands on without a copy."
  @spec pack(table()) :: binary()
  def pack(%{build_id: _build_id, stops: _stops} = table), do: :erlang.term_to_binary(table)

  @doc "The table `binary` packs."
  @spec unpack(binary()) :: table()
  def unpack(binary) when is_binary(binary) do
    table = :erlang.binary_to_term(binary, [:safe])

    Assert.condition(
      match?(%{build_id: _, stops: %{}}, table),
      "a walk link table is a map of stops"
    )

    table
  end

  @doc """
  The identifiers of the stops of `input.positions` that `input.table`, or
  none, has to measure again on the build `input.build_id`.
  """
  @spec stale_stop_ids(%{
          positions: positions(),
          table: table() | nil,
          build_id: String.t()
        }) :: [String.t()]
  def stale_stop_ids(%{positions: positions, table: nil, build_id: _build_id}) do
    Map.keys(positions)
  end

  def stale_stop_ids(%{positions: positions, table: %{build_id: held}, build_id: build_id})
      when held != build_id do
    Map.keys(positions)
  end

  def stale_stop_ids(%{positions: positions, table: %{stops: held}}) do
    index = index(positions)
    changed = changed_positions(positions, held)

    near =
      for place <- changed,
          {_straight_meters, id} <- within(index, place, @radius_meters),
          do: id

    own = for {id, position} <- positions, not same_position?(Map.get(held, id), position), do: id
    near |> Enum.concat(own) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The table for `input.positions` from `input.previous` and the stops measured
  again: `{:ok, %{table: table, stats: stats}}` or `{:error, kind, reason}`
  with `kind` `:corrupt` for a shard that is not a valid shard of the build, `:io` for
  a read that failed, `:deadline` for a computation past `input.deadline_ms`
  on the monotonic clock, `:killed` for a tile's process that outgrew
  `input.child_heap_words_max`, and `:crashed` for one that exited otherwise.

  `input.load_shard` reads the bytes of the shard of a tile: `{:ok, binary}`,
  `{:error, :corrupt}`, or `{:error, {:io, reason}}`. `input.index` is the
  `MapSet` of the tiles that have a shard.
  """
  @spec compute(%{
          :positions => positions(),
          :stop_ids => [String.t()],
          :previous => table() | nil,
          :build_id => String.t(),
          :index => MapSet.t(),
          :load_shard => (Tiles.tile() -> load_result()),
          :deadline_ms => integer(),
          optional(:child_heap_words_max) => pos_integer()
        }) ::
          {:ok, %{table: table(), stats: stats()}}
          | {:error, :corrupt | :io | :deadline | :killed | :crashed, term()}
  def compute(%{positions: positions, stop_ids: stop_ids, build_id: build_id} = input)
      when is_binary(build_id) do
    assert_margin()

    Assert.condition(
      Enum.all?(stop_ids, &Map.has_key?(positions, &1)),
      "every stop to measure has a position"
    )

    initial = %{
      measured: [],
      cache: %{bins: %{}, bytes: %{}, order: []},
      stats: %{straight_link_count: 0, dropped_link_count: 0, read_count: 0}
    }

    context =
      Map.merge(input, %{
        spatial: index(positions),
        child_heap_words_max: Map.get(input, :child_heap_words_max, @child_heap_words_max_default)
      })

    reduced =
      positions
      |> tile_groups(stop_ids)
      |> Enum.reduce_while(initial, fn {tile, cells}, state ->
        case measure_tile(tile, cells, state, context) do
          {:ok, next} -> {:cont, next}
          {:error, _kind, _reason} = failure -> {:halt, failure}
        end
      end)

    case reduced do
      {:error, _kind, _reason} = failure -> failure
      %{measured: measured, stats: stats} -> {:ok, assemble(input, measured, stats)}
    end
  end

  @doc """
  The links of a snapshot of the stops `input.stop_ids`, indexed by their
  position in it, from `input.table`, as the transfers file holds them: a stop
  without a position has none, and a stop keeps its #{@link_count_per_stop_max} nearest
  street links among the stops of the snapshot. Ordered by the stop they
  leave, then the one they reach.
  """
  @spec links(%{stop_ids: [String.t()], positions: positions(), table: table()}) ::
          [SnapshotFormat.transfer()]
  def links(%{stop_ids: stop_ids, positions: positions, table: %{stops: stops}}) do
    indexed = Map.new(Enum.with_index(stop_ids))

    for {stop_id, from_stop} <- Enum.with_index(stop_ids),
        Map.has_key?(positions, stop_id),
        link <- links_from(from_stop, Map.get(stops, stop_id), indexed) do
      link
    end
    |> Enum.sort_by(&{&1.from_stop, &1.to_stop})
  end

  defp links_from(_from_stop, nil, _indexed), do: []

  defp links_from(from_stop, %{links: links}, indexed) do
    reachable = Enum.filter(links, fn {other, _meters} -> Map.has_key?(indexed, other) end)

    reachable
    |> Enum.sort_by(fn {other, meters} -> {meters, other} end)
    |> Enum.take(@link_count_per_stop_max)
    |> Enum.map(fn {other, meters} ->
      %{
        from_stop: from_stop,
        to_stop: Map.fetch!(indexed, other),
        duration_s: Transfers.walk_duration_s(meters)
      }
    end)
  end

  # The margin must hold the longest street and the snap bound, or a street
  # from a stop leaves the pieces of its cell, and be no more than a tile, or
  # the 3 by 3 tiles around a cell's tile no longer hold the margin.
  defp assert_margin do
    snap_meters_max = Search.limits().snap_meters_max
    tile_meters = Tiles.sizes().lat * Geodesy.meters_per_degree() / @units_per_degree

    Assert.condition(
      @margin_meters >= @street_meters_max + snap_meters_max,
      "the margin of #{@margin_meters} m is under the street bound and the snap bound"
    )

    Assert.condition(
      @margin_meters <= tile_meters,
      "the margin of #{@margin_meters} m is more than a tile of #{tile_meters} m"
    )
  end

  # ---- Which stops are measured again.

  defp changed_positions(positions, held) do
    added_or_moved =
      for {id, position} <- positions,
          not same_position?(Map.get(held, id), position),
          do: position

    moved_from =
      for {id, %{lat: lat, lon: lon}} <- held,
          not same_position?(%{lat: lat, lon: lon}, Map.get(positions, id)),
          do: %{lat: lat, lon: lon}

    added_or_moved ++ moved_from
  end

  defp same_position?(%{lat: lat, lon: lon}, %{lat: lat, lon: lon}), do: true
  defp same_position?(_held, _position), do: false

  # ---- The stops by their straight-line neighbors, in the cells of Transfers.

  defp index(positions) do
    lon_m = positions |> Map.values() |> Transfers.lon_m()

    cells =
      Enum.group_by(
        positions,
        fn {_id, position} -> Transfers.cell(position, lon_m) end,
        fn {id, position} -> {id, position} end
      )

    %{cells: cells, lon_m: lon_m}
  end

  defp within(%{cells: cells, lon_m: lon_m}, position, radius_meters) do
    {row, column} = Transfers.cell(position, lon_m)

    for row_step <- -1..1,
        column_step <- -1..1,
        {id, other} <- Map.get(cells, {row + row_step, column + column_step}, []),
        straight_meters = Geodesy.distance_meters(position, other),
        straight_meters <= radius_meters do
      {straight_meters, id}
    end
  end

  # ---- The measuring, tile by tile.

  defp tile_groups(positions, stop_ids) do
    stop_ids
    |> Enum.group_by(fn id -> tile_of(Map.fetch!(positions, id)) end)
    |> Enum.sort()
    |> Enum.map(fn {tile, ids} ->
      {tile, ids |> Enum.group_by(&cell_of(Map.fetch!(positions, &1))) |> Enum.sort()}
    end)
  end

  defp tile_of(%{lat: lat, lon: lon}) do
    Tiles.tile_of(
      {floor(lat * @units_per_degree), floor(lon * @units_per_degree)},
      Tiles.sizes()
    )
  end

  defp cell_of(%{lat: lat, lon: lon}) do
    sizes = Tiles.sizes()
    lat_in_tile = Integer.mod(floor(lat * @units_per_degree), sizes.lat)
    lon_in_tile = Integer.mod(floor(lon * @units_per_degree), sizes.lon)
    {div(lat_in_tile * @cell_rows, sizes.lat), div(lon_in_tile * @cell_columns, sizes.lon)}
  end

  defp measure_tile({row, column} = tile, cells, state, context) do
    if System.monotonic_time(:millisecond) > context.deadline_ms do
      {:error, :deadline, tile}
    else
      window =
        for row_step <- -1..1,
            column_step <- -1..1,
            MapSet.member?(context.index, {row + row_step, column + column_step}),
            do: {row + row_step, column + column_step}

      with {:ok, cache, read_count} <- ensure_shards(window, state.cache, context),
           {:ok, packed, tally} <- measure_in_process(tile, window, cells, cache, context) do
        stats = %{
          state.stats
          | read_count: state.stats.read_count + read_count,
            straight_link_count: state.stats.straight_link_count + tally.straight,
            dropped_link_count: state.stats.dropped_link_count + tally.dropped
        }

        {:ok, %{state | cache: cache, stats: stats, measured: [packed | state.measured]}}
      end
    end
  end

  # A tile is measured in a process that ends with it, so the decoded shards
  # and the graph are freed with it. It gets the shards as binaries, which are
  # not copied, and the stops of the tile with the positions of their
  # neighbors, and returns the links packed.
  defp measure_in_process(tile, window, cells, cache, context) do
    positions = context.positions
    binaries = Enum.map(window, &{&1, Map.fetch!(cache.bins, &1)})

    jobs =
      for {cell, ids} <- cells do
        {cell, Enum.map(ids, &stop_job(&1, positions, context.spatial))}
      end

    parent = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, measure_tile_pure(tile, binaries, jobs)}) end,
        [
          :monitor,
          fullsweep_after: 0,
          max_heap_size: %{size: context.child_heap_words_max, kill: true, error_logger: false}
        ]
      )

    remaining_ms =
      context.deadline_ms
      |> Kernel.-(System.monotonic_time(:millisecond))
      |> max(0)
      |> min(@receive_timeout_max_ms)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :killed, tile}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, :crashed, {tile, reason}}
    after
      remaining_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :deadline, tile}
    end
  end

  defp stop_job(id, positions, spatial) do
    position = Map.fetch!(positions, id)

    candidates =
      for {straight_meters, other} <- within(spatial, position, @radius_meters),
          other != id,
          do: {other, Map.fetch!(positions, other), straight_meters}

    {id, position, candidates}
  end

  # What a tile's process does: decode the shards, and for each cell build one
  # graph and measure its stops. The answer is the stops' links packed, with the
  # counts of the links kept as straight lines and the pairs dropped.
  defp measure_tile_pure(tile, binaries, jobs) do
    case decode_all(binaries) do
      {:ok, shards} ->
        {entries, tally} =
          Enum.reduce(jobs, {%{}, %{straight: 0, dropped: 0}}, fn {cell, stops}, acc ->
            measure_cell(%{tile: tile, cell: cell, stops: stops, shards: shards}, acc)
          end)

        {:ok, :erlang.term_to_binary(entries), tally}

      {:error, bad_tile} ->
        {:error, :corrupt, bad_tile}
    end
  end

  defp decode_all(binaries) do
    Enum.reduce_while(binaries, {:ok, []}, fn {tile, binary}, {:ok, shards} ->
      case Format.decode_shard(binary) do
        {:ok, shard} -> {:cont, {:ok, [shard | shards]}}
        {:error, _refusal} -> {:halt, {:error, tile}}
      end
    end)
  end

  defp measure_cell(%{tile: tile, cell: cell, stops: stops, shards: shards}, {entries, tally}) do
    box = cell_box(tile, cell)
    pieces = for shard <- shards, piece <- shard.pieces, near_box?(piece, box), do: piece

    prepared =
      Search.prepare(%{reference: box.middle, shards: [%{pieces: pieces}], limits: limits()})

    Enum.reduce(stops, {entries, tally}, fn {id, position, candidates}, {held, counts} ->
      answers = answers(prepared, position, candidates)
      {links, tallied} = links_of(candidates, answers)
      entry = %{lat: position.lat, lon: position.lon, links: links}

      {Map.put(held, id, entry),
       %{
         straight: counts.straight + tallied.straight,
         dropped: counts.dropped + tallied.dropped
       }}
    end)
  end

  # The cell's extent in units, widened by the margin in each direction.
  defp cell_box({row, column}, {cell_row, cell_column}) do
    sizes = Tiles.sizes()
    lat_size = div(sizes.lat, @cell_rows)
    lon_size = div(sizes.lon, @cell_columns)
    lat_low = row * sizes.lat + cell_row * lat_size
    lon_low = column * sizes.lon + cell_column * lon_size
    lat_mid_degrees = (lat_low + div(lat_size, 2)) / @units_per_degree
    meters_per_unit = Geodesy.meters_per_degree() / @units_per_degree
    lat_margin = ceil(@margin_meters / meters_per_unit)

    lon_margin =
      ceil(@margin_meters / (meters_per_unit * :math.cos(Geodesy.radians(lat_mid_degrees))))

    %{
      lat_low: lat_low - lat_margin,
      lat_high: lat_low + lat_size + lat_margin,
      lon_low: lon_low - lon_margin,
      lon_high: lon_low + lon_size + lon_margin,
      middle: %{
        lat: (lat_low + div(lat_size, 2)) / @units_per_degree,
        lon: (lon_low + div(lon_size, 2)) / @units_per_degree
      }
    }
  end

  # A piece is near the box when the box of its positions meets it, which
  # keeps every piece that a street within the margin of the cell can use.
  defp near_box?(%{points: points}, box) do
    {lats, lons} = Enum.unzip(points)

    Enum.min(lats) <= box.lat_high and Enum.max(lats) >= box.lat_low and
      Enum.min(lons) <= box.lon_high and Enum.max(lons) >= box.lon_low
  end

  defp limits, do: %{Search.limits() | street_meters_max: @street_meters_max}

  # A cell with no piece in its margin has every end off the graph, so its
  # stops keep their straight lines; one whose graph is past the piece bound
  # answers nothing, and its pairs are dropped.
  defp answers({:no_path, :no_shards}, _position, candidates) do
    Enum.map(candidates, fn _candidate -> {:no_path, :off_graph} end)
  end

  defp answers({:no_path, :cap_reached}, _position, candidates) do
    Enum.map(candidates, fn _candidate -> {:no_path, :cap_reached} end)
  end

  defp answers({:ok, prepared}, position, candidates) do
    chunk_size = limits().target_count_max

    candidates
    |> Enum.chunk_every(chunk_size)
    |> Enum.flat_map(fn chunk ->
      targets = Enum.map(chunk, fn {_other, other_position, _meters} -> other_position end)

      Search.reach_prepared(%{
        prepared: prepared,
        from: position,
        targets: targets,
        limits: limits()
      })
    end)
  end

  defp links_of(candidates, answers) do
    Assert.condition(length(candidates) == length(answers), "an answer for every candidate")

    {links, tally} =
      candidates
      |> Enum.zip(answers)
      |> Enum.reduce({[], %{straight: 0, dropped: 0}}, fn
        {{other, _position, _straight}, {:found, meters}}, {links, tally} ->
          {[{other, meters} | links], tally}

        {{other, _position, straight_meters}, {:no_path, :off_graph}}, {links, tally} ->
          {[{other, straight_meters} | links], %{tally | straight: tally.straight + 1}}

        {_candidate, {:no_path, _reason}}, {links, tally} ->
          {links, %{tally | dropped: tally.dropped + 1}}
      end)

    kept =
      links
      |> Enum.sort_by(fn {other, meters} -> {meters, other} end)
      |> Enum.take(@link_count_per_stop_max)

    {kept, tally}
  end

  # ---- The shards, read at most @read_concurrency at a time and kept by tile as
  # the binaries read.

  defp ensure_shards(window, cache, context) do
    missing = Enum.reject(window, &Map.has_key?(cache.bins, &1))

    stream =
      Task.async_stream(missing, context.load_shard,
        max_concurrency: @read_concurrency,
        timeout: @read_timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )

    results = Enum.zip(missing, stream)

    case first_failure(results) do
      :none ->
        loaded = for {tile, {:ok, {:ok, binary}}} <- results, do: {tile, binary}
        {:ok, keep(cache, loaded, window), length(missing)}

      {:failed, kind, reason} ->
        {:error, kind, reason}
    end
  end

  defp first_failure(results) do
    Enum.find_value(results, :none, fn
      {_tile, {:ok, {:ok, _binary}}} -> nil
      {tile, {:ok, {:error, :corrupt}}} -> {:failed, :corrupt, tile}
      {tile, {:ok, {:error, {:io, reason}}}} -> {:failed, :io, {tile, reason}}
      {tile, {:exit, reason}} -> {:failed, :io, {tile, reason}}
    end)
  end

  # The cache keeps the shards of the window and, of the shards before it, the
  # newest while the bytes held stay within the bound.
  defp keep(cache, loaded, window) do
    bins =
      Enum.reduce(loaded, cache.bins, fn {tile, binary}, held -> Map.put(held, tile, binary) end)

    bytes =
      Enum.reduce(loaded, cache.bytes, fn {tile, binary}, held ->
        Map.put(held, tile, byte_size(binary))
      end)

    order = Enum.uniq(Enum.map(loaded, &elem(&1, 0)) ++ cache.order)
    trim(%{bins: bins, bytes: bytes, order: order}, window)
  end

  # The newest shards first, each kept while the bytes kept stay within the
  # bound, and the window's always, so a window larger than the bound still
  # holds its own shards.
  defp trim(%{bins: bins, bytes: bytes, order: order}, window) do
    {kept, _total} =
      Enum.reduce(order, {[], 0}, fn tile, {kept, total} ->
        size = Map.fetch!(bytes, tile)

        if tile in window or total + size <= @shard_byte_max do
          {[tile | kept], total + size}
        else
          {kept, total}
        end
      end)

    %{bins: Map.take(bins, kept), bytes: Map.take(bytes, kept), order: Enum.reverse(kept)}
  end

  # ---- The table: what was measured and what the previous table still holds.

  defp assemble(input, packed_tiles, stats) do
    positions = input.positions
    stale = MapSet.new(input.stop_ids)

    measured =
      Enum.reduce(packed_tiles, %{}, fn packed, entries ->
        Map.merge(entries, :erlang.binary_to_term(packed, [:safe]))
      end)

    held =
      case input.previous do
        %{build_id: build_id, stops: previous} when build_id == input.build_id ->
          for {id, entry} <- previous,
              Map.has_key?(positions, id),
              not MapSet.member?(stale, id),
              into: %{},
              do: {id, entry}

        _other ->
          %{}
      end

    stops = Map.merge(held, measured)
    Assert.condition(map_size(stops) == map_size(positions), "every stop is in the table")
    link_count = stops |> Map.values() |> Enum.map(&length(&1.links)) |> Enum.sum()

    %{
      table: %{build_id: input.build_id, stops: stops},
      stats:
        Map.merge(stats, %{
          stop_count: map_size(stops),
          measured_stop_count: map_size(measured),
          link_count: link_count
        })
    }
  end
end
