defmodule Gobusgo.Addresses.Accumulator do
  @tail_row_count_max 4
  @house_number_pattern ~r/\A(\d{1,9}) ?([A-Z]?)\z/

  @moduledoc """
  Collects the address records of a county into the streets the shards hold,
  with each street's addresses packed into one binary (`Gobusgo.Addresses.Rows`)
  instead of a term per address.

  `add/2` takes one record as a county's source reads it: the house number
  as the county writes it (`"920 B"` is number 920 with the suffix B), the
  street's four fields, the postal city, and the position in degrees. A
  record is counted and left out when its house number is not a whole number
  with at most one letter after it, when its street name is empty after
  normalization, when its position is not a position on the globe, or when
  its position is outside the bounds the accumulator was given. The counts
  name each cause.

  A street is every address of one normalized street (`Gobusgo.Addresses.Normalize`)
  in one postal city. Rows are gathered per street in a tail of at most
  #{@tail_row_count_max} rows, which is packed into a chunk when it fills, so
  a street holds a few binaries and a short list at a time.

  `finish/1` returns the streets, each with its addresses sorted by number
  and suffix and joined where a number repeats, in the order of their name
  keys, with the SHA-256 of what they hold, which changes when any address,
  street, or city changes. Everything here is pure.
  """

  alias Gobusgo.Addresses.Normalize
  alias Gobusgo.Addresses.Rows

  @type bounds :: %{south: number(), west: number(), north: number(), east: number()}

  @type county_record :: %{
          house_number: String.t(),
          pre_direction: String.t(),
          name: String.t(),
          type: String.t(),
          suf_direction: String.t(),
          city: String.t(),
          lat: number() | nil,
          lon: number() | nil
        }

  @type counts :: %{
          read: non_neg_integer(),
          accepted: non_neg_integer(),
          invalid: non_neg_integer(),
          suffix_unsupported: non_neg_integer(),
          outside_bounds: non_neg_integer()
        }

  @typedoc "One street in one postal city and the packed rows of its addresses."
  @type street :: %{
          street: Normalize.street(),
          name_key: String.t(),
          city: String.t(),
          rows: binary()
        }

  @opaque t :: %__MODULE__{}

  defstruct bounds: nil,
            streets: %{},
            counts: %{read: 0, accepted: 0, invalid: 0, suffix_unsupported: 0, outside_bounds: 0}

  @doc "A new accumulator that keeps the positions inside `bounds`, or every position for `nil`."
  @spec new(bounds() | nil) :: t()
  def new(bounds), do: %__MODULE__{bounds: bounds}

  @doc "Adds `record` to `accumulator`, or counts why it is left out."
  @spec add(t(), county_record()) :: t()
  def add(%__MODULE__{} = accumulator, record) when is_map(record) do
    accumulator = update_in(accumulator.counts.read, &(&1 + 1))

    with {:ok, house_number} <- house_number(record.house_number),
         {:ok, street} <- street(record),
         {:ok, position} <- position(record),
         :ok <- inside(accumulator.bounds, record) do
      row =
        Rows.pack(%{
          number: house_number.number,
          suffix: house_number.suffix,
          lat_microdegrees: position.lat,
          lon_microdegrees: position.lon
        })

      accumulator
      |> add_row(%{street: street, city: clean(record.city), row: row})
      |> update_in([Access.key!(:counts), :accepted], &(&1 + 1))
    else
      {:left_out, reason} -> update_in(accumulator.counts[reason], &(&1 + 1))
    end
  end

  @doc """
  The streets of `accumulator`, the counts, the count of distinct addresses,
  and the SHA-256 of the streets' content.
  """
  @spec finish(t()) :: %{
          streets: [street()],
          counts: counts(),
          address_count: non_neg_integer(),
          sha256: binary()
        }
  def finish(%__MODULE__{streets: entities, counts: counts}) do
    streets =
      entities
      |> Map.values()
      |> Enum.map(&finished_street/1)
      |> Enum.sort_by(&{&1.name_key, Normalize.street_key(&1.street), &1.city})

    %{
      streets: streets,
      counts: counts,
      address_count: streets |> Enum.map(&Rows.count(&1.rows)) |> Enum.sum(),
      sha256: sha256(streets)
    }
  end

  defp house_number(text) do
    cleaned = clean(text)

    case Regex.run(@house_number_pattern, cleaned) do
      [_text, digits, suffix] ->
        {:ok, %{number: String.to_integer(digits), suffix: suffix}}

      nil ->
        is_numbered = String.match?(cleaned, ~r/\A\d{1,9}\b/)
        if is_numbered, do: {:left_out, :suffix_unsupported}, else: {:left_out, :invalid}
    end
  end

  defp street(record) do
    street =
      Normalize.street_from_fields(%{
        pre_direction: record.pre_direction,
        name: record.name,
        type: record.type,
        suf_direction: record.suf_direction
      })

    if street.name == "", do: {:left_out, :invalid}, else: {:ok, street}
  end

  defp position(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon) do
    case Rows.microdegrees(%{lat: lat, lon: lon}) do
      {:ok, position} -> {:ok, position}
      :invalid -> {:left_out, :invalid}
    end
  end

  defp position(_record), do: {:left_out, :invalid}

  defp inside(nil, _record), do: :ok

  defp inside(bounds, %{lat: lat, lon: lon}) do
    is_in_latitude = lat >= bounds.south and lat <= bounds.north
    is_in_longitude = lon >= bounds.west and lon <= bounds.east

    if is_in_latitude and is_in_longitude, do: :ok, else: {:left_out, :outside_bounds}
  end

  defp add_row(accumulator, %{street: street, city: city, row: row}) do
    key = {Normalize.street_key(street), city}

    entity =
      Map.get(accumulator.streets, key, %{
        street: street,
        city: city,
        chunks: [],
        tail: [],
        tail_count: 0
      })

    tail = [row | entity.tail]
    tail_count = entity.tail_count + 1

    entity =
      if tail_count == @tail_row_count_max do
        chunk = tail |> Enum.reverse() |> IO.iodata_to_binary()
        %{entity | chunks: [chunk | entity.chunks], tail: [], tail_count: 0}
      else
        %{entity | tail: tail, tail_count: tail_count}
      end

    %{accumulator | streets: Map.put(accumulator.streets, key, entity)}
  end

  defp finished_street(entity) do
    rows =
      [Enum.reverse(entity.chunks), Enum.reverse(entity.tail)]
      |> IO.iodata_to_binary()
      |> Rows.merge()

    %{
      street: entity.street,
      name_key: Normalize.name_key(entity.street),
      city: entity.city,
      rows: rows
    }
  end

  defp sha256(streets) do
    context =
      Enum.reduce(streets, :crypto.hash_init(:sha256), fn street, context ->
        :crypto.hash_update(context, [
          Normalize.street_key(street.street),
          0,
          street.city,
          0,
          street.rows
        ])
      end)

    :crypto.hash_final(context)
  end

  defp clean(text), do: text |> String.upcase() |> String.split() |> Enum.join(" ")
end
