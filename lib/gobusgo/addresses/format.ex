defmodule Gobusgo.Addresses.Format do
  @shard_kind 3
  @index_kind 4
  @version 1
  @shard_section_count 8
  @index_section_count 4
  @shard_expanded_bytes_max 1_048_576
  @index_expanded_bytes_max 1_048_576
  @digest_bytes 32
  @suffix_letters ?A..?Z
  @address_bytes_min 4

  @moduledoc """
  The address shard kind, kind number #{@shard_kind}, and the address index
  kind, kind number #{@index_kind}, of the packed container
  (`Gobusgo.Packed`), both version #{@version}. Everything here is pure.

  A shard holds one record per street, a street being the addresses of one
  normalized street in one postal city, in the order of the street's name
  key. After the string table it holds #{@shard_section_count} sections, in
  order:

    1. names: a `u32` column, the string index of each street's name;
    2. prefix directionals: a `u32` column of string indexes;
    3. types: a `u32` column of string indexes;
    4. suffix directionals: a `u32` column of string indexes;
    5. postal cities: a `u32` column of string indexes;
    6. numbers: per street a varint count of addresses, at least one, then
       per address the varint difference of its house number from the one
       before it, the first from 0, so the numbers do not decrease;
    7. suffixes: a `u8` column of one byte per address in street order, 0
       for none or an upper case ASCII letter;
    8. positions: per street a path of the container
       (`Gobusgo.Packed.Positions`), one point per address, in
       microdegrees.

  The index holds one record per shard, in the order of their prefixes, and
  #{@index_section_count} sections after the string table:

    1. prefixes: a `u32` column of string indexes, a shard's prefix, which
       ends in `Gobusgo.Addresses.Shards.own_name_mark/0` for the shard of
       the streets named by the prefix alone;
    2. paths: a `u32` column of string indexes, the shard's file name,
       relative to the directory the index is in;
    3. byte sizes: a `u32` column, the size of the shard's gzip stream;
    4. digests: #{@digest_bytes} bytes per shard, the SHA-256 of that stream.

  `expanded_bytes_max/1` bounds the expanded size a reader accepts of each
  kind. `lib/gobusgo/addresses/AGENTS.md` holds the layout's rationale.
  """

  @behaviour Gobusgo.Packed.Kind

  import Kernel, except: [inspect: 1]

  alias Gobusgo.Addresses.Rows
  alias Gobusgo.Assert
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.StringTable
  alias Gobusgo.Packed.Varint

  @type refusal ::
          Packed.refusal()
          | :bad_string_index
          | :bad_numbers
          | :bad_suffix
          | :count_mismatch

  @type decoded_street :: %{
          street: %{
            pre_direction: String.t(),
            name: String.t(),
            type: String.t(),
            suf_direction: String.t()
          },
          city: String.t(),
          rows: binary()
        }

  @type index_entry :: %{
          prefix: String.t(),
          name: String.t(),
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
  Returns a size in bytes that the expanded container of `streets` is at
  least as large as: every address takes at least #{@address_bytes_min}
  bytes, one for the difference of its number, one for its suffix, and one
  for each difference of its position. It is cheap, so a caller can rule a
  group of streets too large without encoding it.
  """
  @spec shard_bytes_min([Gobusgo.Addresses.Accumulator.street()]) :: non_neg_integer()
  def shard_bytes_min(streets) when is_list(streets) do
    address_count = streets |> Enum.map(&Rows.count(&1.rows)) |> Enum.sum()
    address_count * @address_bytes_min
  end

  @doc """
  Returns the expanded container of `streets`, which are in the order of
  their name keys, each with its packed rows (`Gobusgo.Addresses.Rows`)
  sorted by number and suffix. A street holds at least one address. The
  size is not bounded here, since the shards are measured by encoding
  groups of streets that are then split; a caller asserts
  `expanded_bytes_max(:shard)` on the shards it keeps.
  """
  @spec encode_shard([Gobusgo.Addresses.Accumulator.street(), ...]) :: binary()
  def encode_shard([_street | _rest] = streets) do
    {indexes, table} = Enum.map_reduce(streets, StringTable.new(), &intern_street/2)

    [names, pre_directions, types, suf_directions, cities] =
      Enum.zip_with(indexes, &Function.identity/1)

    Packed.encode(%{
      kind: @shard_kind,
      version: @version,
      record_count: length(streets),
      strings: StringTable.strings(table),
      sections: [
        Columns.encode(:u32, names),
        Columns.encode(:u32, pre_directions),
        Columns.encode(:u32, types),
        Columns.encode(:u32, suf_directions),
        Columns.encode(:u32, cities),
        Enum.map(streets, &numbers/1),
        Enum.map(streets, &suffixes/1),
        Enum.map(streets, &positions/1)
      ]
    })
  end

  defp intern_street(%{street: street, city: city}, table) do
    fields = [street.name, street.pre_direction, street.type, street.suf_direction, city]
    Enum.map_reduce(fields, table, fn field, table -> StringTable.intern(table, field) end)
  end

  defp numbers(%{rows: rows}) do
    count = Rows.count(rows)
    Assert.condition(count >= 1, "a street holds at least one address")
    [Varint.encode(count), number_deltas(rows, 0)]
  end

  defp number_deltas(<<>>, _previous), do: []

  defp number_deltas(
         <<number::unsigned-32, _rest_of_row::binary-size(9), rows::binary>>,
         previous
       ) do
    Assert.condition(
      number >= previous,
      "house numbers are in order, got: #{number} after #{previous}"
    )

    [Varint.encode(number - previous) | number_deltas(rows, number)]
  end

  defp suffixes(%{rows: rows}) do
    for <<_number::32, suffix::8, _position::64 <- rows>>, into: <<>> do
      Assert.condition(
        suffix == 0 or suffix in @suffix_letters,
        "a suffix is none or a letter, got: #{suffix}"
      )

      <<suffix>>
    end
  end

  defp positions(%{rows: rows}) do
    points =
      for <<_number::32, _suffix::8, lat::signed-32, lon::signed-32 <- rows>>, do: {lat, lon}

    Positions.encode_path(points)
  end

  @doc "Returns the streets `binary` holds, or the first rule it breaks."
  @spec decode_shard(binary()) :: {:ok, %{streets: [decoded_street()]}} | {:error, refusal()}
  def decode_shard(binary) when is_binary(binary) do
    expectation = %{kind: @shard_kind, versions: [@version], section_count: @shard_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_shard(container)
    end
  end

  defp read_shard(%{record_count: count, strings: strings, sections: sections}) do
    [names, pre_directions, types, suf_directions, cities, numbers, suffixes, positions] =
      sections

    with {:ok, name_texts} <-
           text_column(%{type: :u32, section: names, count: count, strings: strings}),
         {:ok, pre_texts} <-
           text_column(%{type: :u32, section: pre_directions, count: count, strings: strings}),
         {:ok, type_texts} <-
           text_column(%{type: :u32, section: types, count: count, strings: strings}),
         {:ok, suf_texts} <-
           text_column(%{type: :u32, section: suf_directions, count: count, strings: strings}),
         {:ok, city_texts} <-
           text_column(%{type: :u32, section: cities, count: count, strings: strings}),
         {:ok, number_lists} <- read_numbers(numbers, count),
         counts = Enum.map(number_lists, &length/1),
         {:ok, suffix_lists} <- read_suffixes(suffixes, counts),
         {:ok, point_lists} <- read_paths(positions, counts) do
      fields = Enum.zip([name_texts, pre_texts, type_texts, suf_texts, city_texts])
      addresses = Enum.zip([number_lists, suffix_lists, point_lists])

      streets =
        for {{name, pre, type, suf, city}, address_lists} <- Enum.zip(fields, addresses) do
          %{
            street: %{pre_direction: pre, name: name, type: type, suf_direction: suf},
            city: city,
            rows: pack_rows(address_lists)
          }
        end

      {:ok, %{streets: streets}}
    end
  end

  defp text_column(%{type: type, section: section, count: count, strings: strings}) do
    with {:ok, indexes} <- Columns.decode(type, section, count) do
      texts_at(strings, indexes)
    end
  end

  defp texts_at(strings, indexes) do
    if Enum.all?(indexes, &(&1 < tuple_size(strings))) do
      {:ok, Enum.map(indexes, &elem(strings, &1))}
    else
      {:error, :bad_string_index}
    end
  end

  # The numbers of each street, rebuilt from their differences.
  defp read_numbers(section, street_count), do: read_numbers(section, street_count, [])

  defp read_numbers(<<>>, 0, lists), do: {:ok, Enum.reverse(lists)}
  defp read_numbers(_rest, 0, _lists), do: {:error, :bad_numbers}

  defp read_numbers(section, remaining, lists) do
    with {:ok, count, rest} <- Varint.decode(section),
         true <- count >= 1 and count <= byte_size(rest),
         {:ok, numbers, after_street} <- number_run(rest, count, 0, []) do
      read_numbers(after_street, remaining - 1, [numbers | lists])
    else
      false -> {:error, :bad_numbers}
      {:error, :truncated} -> {:error, :bad_numbers}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp number_run(rest, 0, _previous, numbers), do: {:ok, Enum.reverse(numbers), rest}

  defp number_run(binary, remaining, previous, numbers) do
    with {:ok, difference, rest} <- Varint.decode(binary) do
      number = previous + difference

      if number <= Varint.value_max() do
        number_run(rest, remaining - 1, number, [number | numbers])
      else
        {:error, :bad_numbers}
      end
    end
  end

  defp read_suffixes(section, counts) do
    with {:ok, codes} <- Columns.decode(:u8, section, Enum.sum(counts)) do
      if Enum.all?(codes, &(&1 == 0 or &1 in @suffix_letters)) do
        {:ok, split_by(codes, counts)}
      else
        {:error, :bad_suffix}
      end
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

  defp split_by(values, counts) do
    {lists, []} =
      Enum.map_reduce(counts, values, fn count, remaining -> Enum.split(remaining, count) end)

    lists
  end

  defp pack_rows({numbers, suffix_codes, points}) do
    addresses = Enum.zip([numbers, suffix_codes, points])

    for {number, code, {lat, lon}} <- addresses, into: <<>> do
      <<number::unsigned-32, code::unsigned-8, lat::signed-32, lon::signed-32>>
    end
  end

  @doc """
  Returns the expanded container of `entries`, one per shard in the order of
  their prefixes: the `prefix`, the file `name`, the `byte_size` of the
  stored gzip stream, and its `sha256` as 64 lower case hexadecimal digits.
  """
  @spec encode_index([index_entry(), ...]) :: binary()
  def encode_index([_entry | _rest] = entries) do
    {prefixes, table} =
      Enum.map_reduce(entries, StringTable.new(), fn entry, table ->
        StringTable.intern(table, entry.prefix)
      end)

    {paths, table} =
      Enum.map_reduce(entries, table, fn entry, table -> StringTable.intern(table, entry.name) end)

    expanded =
      Packed.encode(%{
        kind: @index_kind,
        version: @version,
        record_count: length(entries),
        strings: StringTable.strings(table),
        sections: [
          Columns.encode(:u32, prefixes),
          Columns.encode(:u32, paths),
          Columns.encode(:u32, Enum.map(entries, & &1.byte_size)),
          Enum.map(entries, &digest/1)
        ]
      })

    assert_expanded_size(:index, expanded)
  end

  @doc """
  Returns `expanded`, the expanded bytes of a file of `kind`, `:shard` or
  `:index`, after asserting that a reader accepts that many.
  """
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

  @doc "Returns the entries `binary` holds, or the first rule it breaks."
  @spec decode_index(binary()) :: {:ok, %{entries: [index_entry()]}} | {:error, refusal()}
  def decode_index(binary) when is_binary(binary) do
    expectation = %{kind: @index_kind, versions: [@version], section_count: @index_section_count}

    with {:ok, container} <- Packed.decode(binary, expectation) do
      read_index(container)
    end
  end

  defp read_index(%{record_count: count, strings: strings, sections: sections}) do
    [prefixes, paths, byte_sizes, digests] = sections

    with {:ok, prefix_texts} <-
           text_column(%{type: :u32, section: prefixes, count: count, strings: strings}),
         {:ok, path_texts} <-
           text_column(%{type: :u32, section: paths, count: count, strings: strings}),
         {:ok, sizes} <- Columns.decode(:u32, byte_sizes, count),
         {:ok, sha256s} <- read_digests(digests, count) do
      entries =
        for {prefix, name, byte_size, sha256} <-
              Enum.zip([prefix_texts, path_texts, sizes, sha256s]) do
          %{prefix: prefix, name: name, byte_size: byte_size, sha256: sha256}
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
          "addressCount" => streets |> Enum.map(&Rows.count(&1.rows)) |> Enum.sum(),
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

  def inspect(_container), do: %{"refused" => "not_address_v1"}

  defp entry_description(entry) do
    %{
      "prefix" => entry.prefix,
      "path" => entry.name,
      "byteSize" => entry.byte_size,
      "sha256" => entry.sha256
    }
  end

  defp street_description(%{street: street, city: city, rows: rows}) do
    %{
      "preDirection" => street.pre_direction,
      "name" => street.name,
      "type" => street.type,
      "sufDirection" => street.suf_direction,
      "city" => city,
      "addresses" =>
        for address <- Rows.unpack(rows) do
          [
            "#{address.number}#{address.suffix}",
            address.lat_microdegrees,
            address.lon_microdegrees
          ]
        end
    }
  end
end
