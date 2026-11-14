defmodule Gobusgo.WalkGraph.Format do
  @shard_kind 8
  @index_kind 9
  @version 1
  @shard_section_count 3
  @index_section_count 3
  @shard_expanded_bytes_max 1_048_576
  @index_expanded_bytes_max 1_048_576
  @piece_points_max 65_535
  @run_length_max 65_535
  @class_max 4
  @morton_bits 16
  @units_per_degree 100_000
  @build_id_pattern ~r/\A[0-9a-f]{16}\z/

  @moduledoc """
  The walk graph shard kind, kind number #{@shard_kind}, and the walk graph
  index kind, kind number #{@index_kind}, of the packed container
  (`Gobusgo.Packed`), both version #{@version}. Everything here is pure.

  A shard holds the pieces of way of one tile (`Gobusgo.WalkGraph.Tiles`),
  one record per piece, with an empty string table and #{@shard_section_count}
  sections after it:

    1. classes: a `u8` column, the class number of each piece
       (`Gobusgo.WalkGraph.Classification`);
    2. counts: a `u16` column, the positions of each piece, at least two;
    3. positions: one path of the container (`Gobusgo.Packed.Positions`)
       through every position of every piece in record order, in the graph's
       units (`units_per_degree/0`), not microdegrees.

  A piece is a polyline between two junctions, or a part of one cut at the
  tile's edge or at #{@piece_points_max} positions; a position two pieces
  share is a junction, and a reader joins pieces that end at one position.
  Pieces are ordered by the Morton code of their first position inside the
  tile, so the path's differences stay small; the order carries no meaning.

  The index names the tiles that have a shard. Its string table holds one
  entry, the build identifier, and it holds one record per run of tiles that
  neighbor in a row, in the order of their rows and then columns, with
  #{@index_section_count} sections after the table: rows, an `i32` column of
  the run's row; starts, an `i32` column of the run's first column; and
  lengths, a `u16` column of the run's tiles, at least one. A shard's file
  name is `shard_file_name/1`: the build identifier, which hashes every
  shard's stream, and the tile, so a name fixes its content and the index
  needs no digest per shard. `expanded_bytes_max/1` bounds the expanded size
  a reader accepts of each kind.
  """

  @behaviour Gobusgo.Packed.Kind

  import Kernel, except: [inspect: 1]

  alias Gobusgo.Assert
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Kinds
  alias Gobusgo.Packed.Positions
  alias Gobusgo.WalkGraph.Tiles

  @type refusal ::
          Packed.refusal()
          | :bad_class
          | :bad_counts
          | :count_mismatch
          | :bad_build_id
          | :bad_runs
  @type piece :: %{class: 0..4, points: [{integer(), integer()}, ...]}
  @type index :: %{build_id: String.t(), tiles: [Tiles.tile(), ...]}

  @doc """
  The graph's positions per degree: a position is a latitude or longitude in
  units of the 100,000th part of a degree, 1.1 m of latitude and 0.75 m of
  longitude at 47.6 degrees north, which a path stores as differences in
  place of microdegrees so that a difference between neighbors takes one
  byte more often than two.
  """
  @spec units_per_degree() :: pos_integer()
  def units_per_degree, do: @units_per_degree

  @doc "The number of the shard kind in the container's header."
  @spec shard_kind() :: pos_integer()
  def shard_kind, do: @shard_kind

  @doc "The number of the index kind in the container's header."
  @spec index_kind() :: pos_integer()
  def index_kind, do: @index_kind

  @doc "The version this module reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The most bytes a file of `kind`, `:shard` or `:index`, may expand to."
  @spec expanded_bytes_max(:shard | :index) :: pos_integer()
  def expanded_bytes_max(:shard), do: @shard_expanded_bytes_max
  def expanded_bytes_max(:index), do: @index_expanded_bytes_max

  @doc """
  The name of the file of the shard of `input.tile` in the build
  `input.build_id`: the shard kind's prefix, the build identifier, the
  tile's row and its column, and the container's suffixes.
  """
  @spec shard_file_name(%{build_id: String.t(), tile: Tiles.tile()}) :: String.t()
  def shard_file_name(%{build_id: build_id, tile: {row, column}}) do
    Assert.condition(
      Regex.match?(@build_id_pattern, build_id),
      "a build identifier is 16 lower case hexadecimal digits, got: #{build_id}"
    )

    {:ok, %{prefix: prefix}} = Kinds.fetch(@shard_kind)
    "#{prefix}-#{build_id}-#{row}_#{column}.bin#{Gobusgo.Compression.suffix()}"
  end

  @doc """
  The pieces of the tile `input.tile`, each `{class, points}` as
  `Gobusgo.WalkGraph.Selection` returns them, in the order a shard stores
  them: by the Morton code of the first position's offset inside the tile,
  then by the points.
  """
  @spec order([{0..4, binary()}], %{tile: Tiles.tile(), tile_sizes: Tiles.sizes()}) :: [piece()]
  def order(pieces, %{tile: {row, column}, tile_sizes: %{lat: lat_size, lon: lon_size}})
      when is_list(pieces) do
    decoded = Enum.map(pieces, &decode_piece/1)

    Enum.sort_by(decoded, fn %{points: [{lat, lon} | _rest]} = piece ->
      {morton(lat - row * lat_size, lon - column * lon_size), piece.points, piece.class}
    end)
  end

  defp decode_piece({class, binary}) do
    points = for <<lat::signed-32, lon::signed-32 <- binary>>, do: {lat, lon}
    %{class: class, points: points}
  end

  defp morton(lat, lon) do
    limit = Bitwise.bsl(1, @morton_bits) - 1

    Assert.condition(
      lat in 0..limit and lon in 0..limit,
      "a piece starts inside its tile, got offsets #{lat}, #{lon}"
    )

    Enum.reduce(0..(@morton_bits - 1), 0, fn bit, code ->
      lat_bit = Bitwise.band(Bitwise.bsr(lat, bit), 1)
      lon_bit = Bitwise.band(Bitwise.bsr(lon, bit), 1)

      Bitwise.bor(
        code,
        Bitwise.bor(Bitwise.bsl(lat_bit, 2 * bit + 1), Bitwise.bsl(lon_bit, 2 * bit))
      )
    end)
  end

  @doc "The expanded container of `pieces`, in the order given. At least one piece."
  @spec encode_shard([piece(), ...]) :: binary()
  def encode_shard([_piece | _rest] = pieces) do
    for piece <- pieces do
      Assert.condition(
        piece.class in 0..@class_max,
        "a piece's class is 0 to #{@class_max}, got: #{piece.class}"
      )

      count = length(piece.points)

      Assert.condition(
        count >= 2 and count <= @piece_points_max,
        "a piece holds 2 to #{@piece_points_max} positions, got: #{count}"
      )
    end

    points = Enum.flat_map(pieces, & &1.points)

    Packed.encode(%{
      kind: @shard_kind,
      version: @version,
      record_count: length(pieces),
      strings: [],
      sections: [
        Columns.encode(:u8, Enum.map(pieces, & &1.class)),
        Columns.encode(:u16, Enum.map(pieces, &length(&1.points))),
        Positions.encode_path(points)
      ]
    })
  end

  @doc "The pieces `binary` holds, or the first rule it breaks."
  @spec decode_shard(binary()) :: {:ok, %{pieces: [piece()]}} | {:error, refusal()}
  def decode_shard(binary) when is_binary(binary) do
    expectation = %{kind: @shard_kind, versions: [@version], section_count: @shard_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_shard(container)
    end
  end

  defp read_shard(%{record_count: count, sections: [classes, counts, positions]}) do
    with {:ok, class_numbers} <- Columns.decode(:u8, classes, count),
         {:ok, point_counts} <- Columns.decode(:u16, counts, count),
         :ok <- check_classes(class_numbers),
         :ok <- check_counts(point_counts),
         {:ok, points, rest} <- Positions.decode_path(positions),
         :ok <- check_rest(rest, points, point_counts) do
      {:ok, %{pieces: group(class_numbers, point_counts, points)}}
    end
  end

  defp check_classes(class_numbers) do
    if Enum.all?(class_numbers, &(&1 <= @class_max)), do: :ok, else: {:error, :bad_class}
  end

  defp check_counts(point_counts) do
    if Enum.all?(point_counts, &(&1 >= 2)), do: :ok, else: {:error, :bad_counts}
  end

  defp check_rest(rest, points, point_counts) do
    cond do
      rest != <<>> -> {:error, :bad_section_size}
      length(points) != Enum.sum(point_counts) -> {:error, :count_mismatch}
      true -> :ok
    end
  end

  defp group(class_numbers, point_counts, points) do
    {pieces, []} =
      Enum.map_reduce(Enum.zip(class_numbers, point_counts), points, fn {class, count},
                                                                        remaining ->
        {piece_points, rest} = Enum.split(remaining, count)
        {%{class: class, points: piece_points}, rest}
      end)

    pieces
  end

  @doc """
  The expanded container of the index of the build `input.build_id` over
  `input.tiles`, which are distinct and in the order of their rows and then
  columns, at least one.
  """
  @spec encode_index(index()) :: binary()
  def encode_index(%{build_id: build_id, tiles: [_tile | _rest] = tiles}) do
    Assert.condition(
      Regex.match?(@build_id_pattern, build_id),
      "a build identifier is 16 lower case hexadecimal digits, got: #{build_id}"
    )

    Assert.condition(
      tiles == tiles |> Enum.sort() |> Enum.dedup(),
      "the tiles of an index are distinct and in order"
    )

    runs = runs(tiles)

    expanded =
      Packed.encode(%{
        kind: @index_kind,
        version: @version,
        record_count: length(runs),
        strings: [build_id],
        sections: [
          Columns.encode(:i32, Enum.map(runs, &elem(&1.start, 0))),
          Columns.encode(:i32, Enum.map(runs, &elem(&1.start, 1))),
          Columns.encode(:u16, Enum.map(runs, & &1.length))
        ]
      })

    assert_expanded_size(:index, expanded)
  end

  # Tiles of one row whose columns follow one another, cut at the length a
  # run's column can hold.
  defp runs(tiles) do
    tiles
    |> Enum.reduce([], &extend_run/2)
    |> Enum.reverse()
  end

  defp extend_run({row, column}, [%{start: {row, start_column}, length: run_length} = run | rest])
       when column == start_column + run_length and run_length < @run_length_max do
    [%{run | length: run_length + 1} | rest]
  end

  defp extend_run(tile, runs), do: [%{start: tile, length: 1} | runs]

  @doc "`expanded`, the expanded bytes of a file of `kind`, after asserting that a reader accepts that many."
  @spec assert_expanded_size(:shard | :index, binary()) :: binary()
  def assert_expanded_size(kind, expanded) when is_binary(expanded) do
    bytes_max = expanded_bytes_max(kind)

    Assert.condition(
      byte_size(expanded) <= bytes_max,
      "a #{kind} must expand to at most #{bytes_max} bytes, got: #{byte_size(expanded)}"
    )

    expanded
  end

  @doc "The index `binary` holds, or the first rule it breaks."
  @spec decode_index(binary()) :: {:ok, index()} | {:error, refusal()}
  def decode_index(binary) when is_binary(binary) do
    expectation = %{kind: @index_kind, versions: [@version], section_count: @index_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_index(container)
    end
  end

  defp read_index(%{record_count: count, strings: strings, sections: [rows, starts, lengths]}) do
    with {:ok, build_id} <- read_build_id(strings),
         {:ok, row_numbers} <- Columns.decode(:i32, rows, count),
         {:ok, start_columns} <- Columns.decode(:i32, starts, count),
         {:ok, run_lengths} <- Columns.decode(:u16, lengths, count),
         :ok <- check_run_lengths(run_lengths) do
      tiles =
        for {row, start, length} <- Enum.zip([row_numbers, start_columns, run_lengths]),
            column <- start..(start + length - 1)//1,
            do: {row, column}

      {:ok, %{build_id: build_id, tiles: tiles}}
    end
  end

  defp read_build_id({build_id}) do
    if Regex.match?(@build_id_pattern, build_id),
      do: {:ok, build_id},
      else: {:error, :bad_build_id}
  end

  defp read_build_id(_strings), do: {:error, :bad_build_id}

  defp check_run_lengths(lengths) do
    if lengths != [] and Enum.all?(lengths, &(&1 >= 1)), do: :ok, else: {:error, :bad_runs}
  end

  @doc "Describes a decoded container for `mix gobusgo.packed.decode --kind-module`."
  @impl Gobusgo.Packed.Kind
  def inspect(%{kind: @shard_kind, version: @version} = container) do
    case read_shard(container) do
      {:ok, %{pieces: pieces}} ->
        %{
          "kind" => @shard_kind,
          "version" => @version,
          "pieceCount" => length(pieces),
          "pieces" => Enum.map(pieces, &piece_description/1)
        }

      {:error, reason} ->
        %{"refused" => Atom.to_string(reason)}
    end
  end

  def inspect(%{kind: @index_kind, version: @version} = container) do
    case read_index(container) do
      {:ok, %{build_id: build_id, tiles: tiles}} ->
        %{
          "kind" => @index_kind,
          "version" => @version,
          "buildId" => build_id,
          "tileCount" => length(tiles),
          "tiles" => Enum.map(tiles, &Tuple.to_list/1)
        }

      {:error, reason} ->
        %{"refused" => Atom.to_string(reason)}
    end
  end

  def inspect(_container), do: %{"refused" => "not_walk_graph_v1"}

  defp piece_description(%{class: class, points: points}) do
    %{"class" => class, "points" => Enum.map(points, &Tuple.to_list/1)}
  end
end
