defmodule Gobusgo.Intersections.Format do
  @shard_kind 6
  @index_kind 7
  @version 1
  @shard_section_count 4
  @index_section_count 3
  @shard_expanded_bytes_max 1_048_576
  @index_expanded_bytes_max 1_048_576
  @digest_bytes 32
  @crossing_bytes_min 6

  @moduledoc """
  The intersection shard kind, kind number #{@shard_kind}, and the
  intersection index kind, kind number #{@index_kind}, of the packed
  container (`Gobusgo.Packed`), both version #{@version}. Everything here is
  pure.

  A shard holds one record per street, in the order of the streets' shard
  keys, and #{@shard_section_count} sections after the string table:

    1. keys: a `u32` column, the string index of each street's key
       (`Gobusgo.Intersections.Names`);
    2. counts: a `u32` column, the crossings of each street, at least one;
    3. others: a `u32` column of the string index of the other street of
       every crossing, in street order, as many as the counts sum to;
    4. positions: per street a path of the container
       (`Gobusgo.Packed.Positions`), one point per crossing, in
       microdegrees.

  A crossing is stored under both of its streets. The index holds one record
  per shard, in the order of their prefixes, and #{@index_section_count}
  sections after the string table: prefixes, byte sizes, and digests of
  #{@digest_bytes} bytes, as the address index holds them
  (`Gobusgo.Addresses.Format`). The index holds no file names: a shard's
  file is in the directory of the index, named by `Gobusgo.Packed.file_name/1`
  from its kind and digest. `expanded_bytes_max/1` bounds the expanded size a
  reader accepts of each kind.
  """

  @behaviour Gobusgo.Packed.Kind

  import Kernel, except: [inspect: 1]

  alias Gobusgo.Assert
  alias Gobusgo.Intersections.Streets
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.StringTable

  @type refusal :: Packed.refusal() | :bad_string_index | :count_mismatch | :bad_counts

  @type decoded_street :: %{
          key: String.t(),
          crossings: [
            %{other: String.t(), lat_microdegrees: integer(), lon_microdegrees: integer()}
          ]
        }

  @type index_entry :: %{
          prefix: String.t(),
          byte_size: non_neg_integer(),
          sha256: String.t()
        }

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
  A size in bytes that the expanded container of `streets` is at least as
  large as: a crossing takes four bytes for its other street and two for
  the differences of its position. It is cheap, so a caller can rule a
  group of streets too large without encoding it.
  """
  @spec shard_bytes_min([Streets.street()]) :: non_neg_integer()
  def shard_bytes_min(streets) when is_list(streets) do
    crossing_count = streets |> Enum.map(&length(&1.crossings)) |> Enum.sum()
    crossing_count * @crossing_bytes_min
  end

  @doc """
  The expanded container of `streets`, which are in the order of their shard
  keys. A street holds at least one crossing. The size is not bounded here,
  since the shards are measured by encoding groups of streets that are then
  split; a caller asserts `expanded_bytes_max(:shard)` on the shards it
  keeps.
  """
  @spec encode_shard([Streets.street(), ...]) :: binary()
  def encode_shard([_street | _rest] = streets) do
    {keys, table} =
      Enum.map_reduce(streets, StringTable.new(), fn street, table ->
        StringTable.intern(table, street.key)
      end)

    {others, table} =
      Enum.map_reduce(streets, table, fn street, table ->
        Enum.map_reduce(street.crossings, table, &StringTable.intern(&2, &1.other))
      end)

    Packed.encode(%{
      kind: @shard_kind,
      version: @version,
      record_count: length(streets),
      strings: StringTable.strings(table),
      sections: [
        Columns.encode(:u32, keys),
        Columns.encode(:u32, Enum.map(streets, &crossing_count/1)),
        Columns.encode(:u32, List.flatten(others)),
        Enum.map(streets, &positions/1)
      ]
    })
  end

  defp crossing_count(%{crossings: crossings}) do
    count = length(crossings)
    Assert.condition(count >= 1, "a street holds at least one crossing")
    count
  end

  defp positions(%{crossings: crossings}) do
    points = for crossing <- crossings, do: {crossing.lat_microdegrees, crossing.lon_microdegrees}
    Positions.encode_path(points)
  end

  @doc "The streets `binary` holds, or the first rule it breaks."
  @spec decode_shard(binary()) :: {:ok, %{streets: [decoded_street()]}} | {:error, refusal()}
  def decode_shard(binary) when is_binary(binary) do
    expectation = %{kind: @shard_kind, versions: [@version], section_count: @shard_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_shard(container)
    end
  end

  defp read_shard(%{record_count: count, strings: strings, sections: sections}) do
    [keys, counts, others, positions] = sections

    with {:ok, key_texts} <- text_column(%{section: keys, count: count, strings: strings}),
         {:ok, crossing_counts} <- read_counts(counts, count),
         total = Enum.sum(crossing_counts),
         {:ok, other_texts} <- text_column(%{section: others, count: total, strings: strings}),
         {:ok, point_lists} <- read_paths(positions, crossing_counts) do
      streets =
        for {key, crossing_list} <-
              Enum.zip(key_texts, crossings(crossing_counts, other_texts, point_lists)) do
          %{key: key, crossings: crossing_list}
        end

      {:ok, %{streets: streets}}
    end
  end

  defp text_column(%{section: section, count: count, strings: strings}) do
    with {:ok, indexes} <- Columns.decode(:u32, section, count) do
      if Enum.all?(indexes, &(&1 < tuple_size(strings))) do
        {:ok, Enum.map(indexes, &elem(strings, &1))}
      else
        {:error, :bad_string_index}
      end
    end
  end

  defp read_counts(section, count) do
    with {:ok, counts} <- Columns.decode(:u32, section, count) do
      if Enum.all?(counts, &(&1 >= 1)), do: {:ok, counts}, else: {:error, :bad_counts}
    end
  end

  defp read_paths(section, counts), do: read_paths(section, counts, [])

  defp read_paths(<<>>, [], lists), do: {:ok, Enum.reverse(lists)}
  defp read_paths(_rest, [], _lists), do: {:error, :bad_section_size}
  defp read_paths(<<>>, [_count | _counts], _lists), do: {:error, :truncated}

  defp read_paths(section, [count | counts], lists) do
    with {:ok, points, rest} <- Positions.decode_path(section) do
      if length(points) == count do
        read_paths(rest, counts, [points | lists])
      else
        {:error, :count_mismatch}
      end
    end
  end

  defp crossings(counts, other_texts, point_lists) do
    {lists, []} =
      Enum.map_reduce(Enum.zip(counts, point_lists), other_texts, fn {count, points}, remaining ->
        {street_others, rest} = Enum.split(remaining, count)

        crossing_list =
          for {other, {lat, lon}} <- Enum.zip(street_others, points) do
            %{other: other, lat_microdegrees: lat, lon_microdegrees: lon}
          end

        {crossing_list, rest}
      end)

    lists
  end

  @doc """
  The expanded container of `entries`, one per shard in the order of their
  prefixes: the `prefix`, the `byte_size` of the stored gzip stream, and its
  `sha256` as 64 lower case hexadecimal digits.
  """
  @spec encode_index([index_entry(), ...]) :: binary()
  def encode_index([_entry | _rest] = entries) do
    {prefixes, table} =
      Enum.map_reduce(entries, StringTable.new(), fn entry, table ->
        StringTable.intern(table, entry.prefix)
      end)

    expanded =
      Packed.encode(%{
        kind: @index_kind,
        version: @version,
        record_count: length(entries),
        strings: StringTable.strings(table),
        sections: [
          Columns.encode(:u32, prefixes),
          Columns.encode(:u32, Enum.map(entries, & &1.byte_size)),
          Enum.map(entries, &digest/1)
        ]
      })

    assert_expanded_size(:index, expanded)
  end

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

  defp digest(%{sha256: sha256}) do
    decoded = Base.decode16(sha256, case: :lower)

    Assert.condition(
      match?({:ok, bytes} when byte_size(bytes) == @digest_bytes, decoded),
      "a digest is #{@digest_bytes * 2} lower case hexadecimal digits, got: #{sha256}"
    )

    {:ok, bytes} = decoded
    bytes
  end

  @doc "The entries `binary` holds, or the first rule it breaks."
  @spec decode_index(binary()) :: {:ok, %{entries: [index_entry()]}} | {:error, refusal()}
  def decode_index(binary) when is_binary(binary) do
    expectation = %{kind: @index_kind, versions: [@version], section_count: @index_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_index(container)
    end
  end

  defp read_index(%{record_count: count, strings: strings, sections: sections}) do
    [prefixes, byte_sizes, digests] = sections

    with {:ok, prefix_texts} <- text_column(%{section: prefixes, count: count, strings: strings}),
         {:ok, sizes} <- Columns.decode(:u32, byte_sizes, count),
         {:ok, sha256s} <- read_digests(digests, count) do
      entries =
        for {prefix, byte_size, sha256} <- Enum.zip([prefix_texts, sizes, sha256s]) do
          %{prefix: prefix, byte_size: byte_size, sha256: sha256}
        end

      {:ok, %{entries: entries}}
    end
  end

  defp read_digests(section, count) do
    if byte_size(section) == count * @digest_bytes do
      digests = for <<digest::binary-size(@digest_bytes) <- section>>, do: digest
      {:ok, Enum.map(digests, &Base.encode16(&1, case: :lower))}
    else
      {:error, :bad_section_size}
    end
  end

  @doc "Describes a decoded container for `mix gobusgo.packed.decode --kind-module`."
  @impl Gobusgo.Packed.Kind
  def inspect(%{kind: @shard_kind, version: @version} = container) do
    case read_shard(container) do
      {:ok, %{streets: streets}} ->
        %{
          "kind" => @shard_kind,
          "version" => @version,
          "streetCount" => length(streets),
          "crossingCount" => streets |> Enum.map(&length(&1.crossings)) |> Enum.sum(),
          "streets" => Enum.map(streets, &street_description/1)
        }

      {:error, reason} ->
        %{"refused" => Atom.to_string(reason)}
    end
  end

  def inspect(%{kind: @index_kind, version: @version} = container) do
    case read_index(container) do
      {:ok, %{entries: entries}} ->
        %{
          "kind" => @index_kind,
          "version" => @version,
          "shardCount" => length(entries),
          "shards" => Enum.map(entries, &entry_description/1)
        }

      {:error, reason} ->
        %{"refused" => Atom.to_string(reason)}
    end
  end

  def inspect(_container), do: %{"refused" => "not_intersections_v1"}

  defp entry_description(entry) do
    %{
      "prefix" => entry.prefix,
      "path" => Packed.file_name(%{kind: @shard_kind, sha256: entry.sha256}),
      "byteSize" => entry.byte_size,
      "sha256" => entry.sha256
    }
  end

  defp street_description(%{key: key, crossings: crossings}) do
    %{
      "key" => key,
      "crossings" =>
        for crossing <- crossings do
          [crossing.other, crossing.lat_microdegrees, crossing.lon_microdegrees]
        end
    }
  end
end
