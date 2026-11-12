defmodule Gobusgo.Places.Format do
  @kind 5
  @version 2
  @versions_read [1, 2]
  @section_counts %{1 => 8, 2 => 9}
  @section_count Map.fetch!(@section_counts, @version)
  @expanded_bytes_max 8 * 1_024 * 1_024
  @alias_count_max 255

  @moduledoc """
  The places kind, version #{@version}, of the packed container
  (`Gobusgo.Packed`): kind number #{@kind}, one record per place. Everything
  here is pure. `decode/1` also reads version 1, whose first
  #{@section_counts[1]} sections these are, so every place of a version 1
  file has the empty locality.

  After the string table the kind holds #{@section_count} sections, in order:

    1. names: a `u32` column, the string index of each place's name;
    2. alias counts: a `u8` column, the aliases of each place, at most
       #{@alias_count_max};
    3. alias names: a `u32` column of the string index of every alias, in
       place order, as many as the alias counts sum to;
    4. positions: the container's positions, latitude and longitude in
       microdegrees, none unknown;
    5. categories: a `u8` column, the index of each place's category in the
       category names;
    6. prominences: a `u8` column;
    7. areas: a `u8` column;
    8. labels: a `u32` column of string indexes, the source date first, then
       the category names in index order, at least one;
    9. localities: a `u32` column, the string index of each place's locality
       (`Gobusgo.Places.Locality`), the empty string for none, at most
       `Gobusgo.Places.Locality.length_max/0` characters.

  Prominence and area are separate scores, never added in the file.
  `expanded_bytes_max/0` bounds the expanded size a reader accepts.

  `decode/1` returns the rows of `Gobusgo.Places.Records`, so a file's rows
  round-trip through it.
  """

  @behaviour Gobusgo.Packed.Kind

  import Kernel, except: [inspect: 1]

  alias Gobusgo.Assert
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.StringTable
  alias Gobusgo.Places.Classification
  alias Gobusgo.Places.Locality
  alias Gobusgo.Places.Records
  alias Gobusgo.Places.Selection

  @type refusal ::
          Packed.refusal()
          | :alias_counts
          | :bad_category
          | :bad_string_index
          | :bad_labels
          | :bad_locality
          | :unknown_position

  @type decoded :: %{
          source_date: String.t(),
          categories: [String.t()],
          places: [Records.row()]
        }

  @doc "The number of the places kind in the container's header."
  @spec kind() :: pos_integer()
  def kind, do: @kind

  @doc "The version this module reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The sections the kind holds after the string table."
  @spec section_count() :: pos_integer()
  def section_count, do: @section_count

  @doc "The most bytes a places file may expand to."
  @spec expanded_bytes_max() :: pos_integer()
  def expanded_bytes_max, do: @expanded_bytes_max

  @doc """
  Returns the expanded container of `source_date` and `places`, the
  candidates of `Gobusgo.Places.Selection`, the categories of
  `Gobusgo.Places.Classification`.
  """
  @spec encode(%{source_date: String.t(), places: [Selection.candidate()]}) :: binary()
  def encode(%{source_date: source_date, places: places}) when is_list(places) do
    rows = Enum.map(places, &Records.row/1)
    categories = Classification.categories()

    {names, table} =
      Enum.map_reduce(rows, StringTable.new(), fn [name | _row], table ->
        StringTable.intern(table, name)
      end)

    {alias_lists, table} =
      Enum.map_reduce(rows, table, fn [_name, aliases | _row], table ->
        Enum.map_reduce(aliases, table, &StringTable.intern(&2, &1))
      end)

    {localities, table} =
      Enum.map_reduce(rows, table, fn row, table ->
        locality = List.last(row)
        assert_locality(locality)
        StringTable.intern(table, locality)
      end)

    {labels, table} =
      Enum.map_reduce([source_date | categories], table, &StringTable.intern(&2, &1))

    Packed.encode(%{
      kind: @kind,
      version: @version,
      record_count: length(rows),
      strings: StringTable.strings(table),
      sections: [
        Columns.encode(:u32, names),
        Columns.encode(:u8, alias_counts(alias_lists)),
        Columns.encode(:u32, List.flatten(alias_lists)),
        Positions.encode(positions(rows)),
        Columns.encode(:u8, for([_n, _a, _lat, _lon, category | _row] <- rows, do: category)),
        Columns.encode(
          :u8,
          for([_n, _a, _lat, _lon, _c, prominence | _row] <- rows, do: prominence)
        ),
        Columns.encode(:u8, for([_n, _a, _lat, _lon, _c, _p, area, _l] <- rows, do: area)),
        Columns.encode(:u32, labels),
        Columns.encode(:u32, localities)
      ]
    })
  end

  defp assert_locality(locality) do
    count = locality |> String.codepoints() |> length()

    Assert.condition(
      count <= Locality.length_max(),
      "a locality has at most #{Locality.length_max()} characters, got: #{count}"
    )
  end

  defp alias_counts(alias_lists) do
    for indexes <- alias_lists do
      count = length(indexes)

      Assert.condition(
        count <= @alias_count_max,
        "a place has at most #{@alias_count_max} aliases, got: #{count}"
      )

      count
    end
  end

  defp positions(rows) do
    for [_name, _aliases, lat, lon | _row] <- rows do
      point = {lat, lon}

      Assert.condition(
        Positions.point?(point),
        "a place needs a known position, got: #{Kernel.inspect(point)}"
      )

      point
    end
  end

  @doc "Returns the places `binary` holds, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, decoded()} | {:error, refusal()}
  def decode(binary) when is_binary(binary) do
    expectation = %{kind: @kind, versions: @versions_read, section_count: :any}

    with {:ok, container} <- Packed.decode(binary, expectation),
         :ok <- check_section_count(container) do
      read(container)
    end
  end

  defp check_section_count(%{version: version, sections: sections}) do
    if length(sections) == Map.fetch!(@section_counts, version),
      do: :ok,
      else: {:error, :section_count}
  end

  defp read(%{record_count: count, strings: strings, sections: sections}) do
    [names, alias_counts, alias_names, positions, categories, prominences, areas, labels | rest] =
      sections

    with {:ok, name_indexes} <- Columns.decode(:u32, names, count),
         {:ok, counts} <- Columns.decode(:u8, alias_counts, count),
         {:ok, alias_indexes} <- alias_column(alias_names, Enum.sum(counts)),
         {:ok, points} <- decode_positions(positions, count),
         {:ok, category_indexes} <- Columns.decode(:u8, categories, count),
         {:ok, prominence_values} <- Columns.decode(:u8, prominences, count),
         {:ok, area_values} <- Columns.decode(:u8, areas, count),
         {:ok, label_indexes} <- label_column(labels),
         {:ok, [source_date | category_names]} <- strings_at(strings, label_indexes),
         :ok <- check_categories(category_indexes, length(category_names)),
         {:ok, place_names} <- strings_at(strings, name_indexes),
         {:ok, alias_texts} <- strings_at(strings, alias_indexes),
         {:ok, locality_texts} <- read_localities(rest, strings, count) do
      aliases = alias_lists(counts, alias_texts)

      places =
        place_rows(%{
          names: place_names,
          aliases: aliases,
          points: points,
          columns: Enum.zip([category_indexes, prominence_values, area_values, locality_texts])
        })

      {:ok, %{source_date: source_date, categories: category_names, places: places}}
    end
  end

  # A version 1 file has no localities section, so every place has none.
  defp read_localities([], _strings, count), do: {:ok, List.duplicate("", count)}

  defp read_localities([section], strings, count) do
    with {:ok, indexes} <- Columns.decode(:u32, section, count),
         {:ok, texts} <- strings_at(strings, indexes) do
      if Enum.all?(texts, &(length(String.codepoints(&1)) <= Locality.length_max())),
        do: {:ok, texts},
        else: {:error, :bad_locality}
    end
  end

  defp alias_column(section, total) do
    case Columns.decode(:u32, section, total) do
      {:ok, indexes} -> {:ok, indexes}
      {:error, :bad_section_size} -> {:error, :alias_counts}
    end
  end

  defp decode_positions(section, count) do
    with {:ok, positions} <- Positions.decode(section, count) do
      if Enum.member?(positions, :unknown),
        do: {:error, :unknown_position},
        else: {:ok, positions}
    end
  end

  defp label_column(section) do
    width = Columns.width(:u32)

    if rem(byte_size(section), width) == 0 and byte_size(section) >= 2 * width do
      Columns.decode(:u32, section, div(byte_size(section), width))
    else
      {:error, :bad_labels}
    end
  end

  defp strings_at(strings, indexes) do
    if Enum.all?(indexes, &(&1 < tuple_size(strings))) do
      {:ok, Enum.map(indexes, &elem(strings, &1))}
    else
      {:error, :bad_string_index}
    end
  end

  defp check_categories(indexes, category_count) do
    if Enum.all?(indexes, &(&1 < category_count)), do: :ok, else: {:error, :bad_category}
  end

  defp alias_lists(counts, alias_texts) do
    {lists, []} =
      Enum.map_reduce(counts, alias_texts, fn count, remaining -> Enum.split(remaining, count) end)

    lists
  end

  defp place_rows(%{names: names, aliases: aliases, points: points, columns: columns}) do
    for {{name, place_aliases}, {{lat, lon}, {category, prominence, area, locality}}} <-
          Enum.zip(Enum.zip(names, aliases), Enum.zip(points, columns)) do
      [name, place_aliases, lat, lon, category, prominence, area, locality]
    end
  end

  @doc "Describes a decoded container for `mix gobusgo.packed.decode --kind-module`."
  @impl Gobusgo.Packed.Kind
  def inspect(%{kind: @kind, version: version, record_count: count} = container)
      when version in @versions_read do
    case read(%{record_count: count, strings: container.strings, sections: container.sections}) do
      {:ok, decoded} ->
        %{
          "kind" => @kind,
          "version" => version,
          "placeCount" => count,
          "sourceDate" => decoded.source_date,
          "categories" => decoded.categories,
          "places" => decoded.places
        }

      {:error, reason} ->
        %{"refused" => Atom.to_string(reason)}
    end
  end

  def inspect(_container), do: %{"refused" => "not_places"}
end
