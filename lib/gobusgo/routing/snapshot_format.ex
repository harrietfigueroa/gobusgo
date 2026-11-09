defmodule Gobusgo.Routing.SnapshotFormat do
  @magic "GBRT"
  @version 2
  @header_bytes 16
  @connection_bytes 24
  @transfer_bytes 12
  @position_bytes 8
  @string_bytes_max 0xFFFF
  @position_unknown -0x80000000
  @lat_microdegrees_max 90_000_000
  @lon_microdegrees_max 180_000_000

  @kinds %{stops: 1, trips: 2, transfers: 3, connections: 4, positions: 5}

  @moduledoc """
  The packed binary files of a routing snapshot, format version #{@version}.
  Everything here is pure, and every number is little-endian, the byte order
  of WebAssembly and of every browser a JavaScript reader runs in.

  Every file starts with a header of #{@header_bytes} bytes: the magic
  `#{@magic}`, the format version as a `u16`, the file kind as a `u16`
  (#{Enum.map_join(@kinds, ", ", fn {kind, code} -> "#{code} #{kind}" end)}),
  the record count as a `u32`, and a `u32` of zero. The records follow.

    * Stops: per stop, its identifier as a `u16` byte length and UTF-8
      bytes. A stop's index is its position.
    * Trips: per trip, its identifier and its route's identifier, each as a
      `u16` byte length and UTF-8 bytes, then a `u8` service day offset: `0`
      for a trip of the snapshot's service date, `1` for one of the date
      before. A trip's index is its position.
    * Transfers: per walking link, #{@transfer_bytes} bytes: the `u32` stop
      index it leaves, the `u32` stop index it reaches, and its `u32`
      duration in seconds.
    * Connections: per connection, #{@connection_bytes} bytes: the `i32`
      departure and arrival in seconds from the start of the snapshot's
      service day, the `u32` departure and arrival stop indexes, the `u32`
      trip index, the `u16` sequence of the connection within its trip, a
      `u8` of flags, bit 0 set where riders may board at the departure stop
      and bit 1 where they may leave at the arrival stop, and a `u8` of
      zero.
    * Positions: per stop, in the order of the stops file,
      #{@position_bytes} bytes: the `i32` latitude and the `i32` longitude
      in millionths of a degree, or #{@position_unknown} on both for a stop
      with no known position.

  `decode/1` refuses a file of another magic, version, or kind, one whose
  length does not fit its count, and a position outside the range of its
  axis or unknown on one axis only.
  """

  @type kind :: :stops | :trips | :transfers | :connections | :positions

  @type trip :: %{id: String.t(), route_id: String.t(), service_day_offset: 0 | 1}
  @type transfer :: %{
          from_stop: non_neg_integer(),
          to_stop: non_neg_integer(),
          duration_s: non_neg_integer()
        }
  @type connection :: %{
          departure_s: integer(),
          arrival_s: integer(),
          departure_stop: non_neg_integer(),
          arrival_stop: non_neg_integer(),
          trip: non_neg_integer(),
          sequence: non_neg_integer(),
          boarding: boolean(),
          alighting: boolean()
        }
  @type position :: %{lat_microdegrees: integer(), lon_microdegrees: integer()} | :unknown

  @typedoc """
    * `:invalid_header` — the file does not start with this format's header
      of a known kind.
    * `:unsupported_version` — the header names another format version.
    * `:invalid_length` — the records do not fill the file as the count
      says.
    * `:invalid_position` — a position lies outside the range of its axis,
      or is unknown on one axis only.
  """
  @type decode_error ::
          :invalid_header | :unsupported_version | :invalid_length | :invalid_position

  @doc "The format version this module writes and reads."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the file of `kind` that holds `records`, in their order."
  @spec encode(kind(), [String.t()] | [trip()] | [transfer()] | [connection()] | [position()]) ::
          binary()
  def encode(kind, records) when is_map_key(@kinds, kind) and is_list(records) do
    body = for record <- records, into: <<>>, do: encode_record(kind, record)
    header(kind, length(records)) <> body
  end

  @doc """
  Returns the record of `connection`, the #{@connection_bytes} bytes the
  connections file holds for it, so a builder can write a file's records one
  at a time and put them under a header with `encode_packed/2`.
  """
  @spec encode_connection(connection()) :: binary()
  def encode_connection(connection), do: encode_record(:connections, connection)

  @doc """
  Returns the departure in seconds of the record at `index` of `body`, a
  body of connection records.
  """
  @spec connection_departure_s(binary(), non_neg_integer()) :: integer()
  def connection_departure_s(body, index) when is_integer(index) and index >= 0 do
    offset = index * @connection_bytes
    <<_before::binary-size(^offset), departure_s::little-signed-32, _rest::binary>> = body
    departure_s
  end

  @doc """
  Returns the arrival in seconds of the record at `index` of `body`, a body
  of connection records.
  """
  @spec connection_arrival_s(binary(), non_neg_integer()) :: integer()
  def connection_arrival_s(body, index) when is_integer(index) and index >= 0 do
    offset = index * @connection_bytes + 4
    <<_before::binary-size(^offset), arrival_s::little-signed-32, _rest::binary>> = body
    arrival_s
  end

  @doc "The bytes of one connection record."
  @spec connection_bytes() :: pos_integer()
  def connection_bytes, do: @connection_bytes

  @doc """
  Returns the connections file whose records are `body`, records already in
  this format's layout, as `encode_connection/1` returns them.
  """
  @spec encode_packed(:connections, binary()) :: binary()
  def encode_packed(:connections, body) when rem(byte_size(body), @connection_bytes) == 0 do
    header(:connections, div(byte_size(body), @connection_bytes)) <> body
  end

  defp header(kind, count) do
    <<@magic, @version::little-16, Map.fetch!(@kinds, kind)::little-16, count::little-32,
      0::little-32>>
  end

  defp encode_record(:stops, stop_id), do: string(stop_id)

  defp encode_record(:trips, %{id: id, route_id: route_id, service_day_offset: offset})
       when offset in [0, 1] do
    string(id) <> string(route_id) <> <<offset::8>>
  end

  defp encode_record(:transfers, %{from_stop: from, to_stop: to, duration_s: duration_s}) do
    <<from::little-32, to::little-32, duration_s::little-32>>
  end

  defp encode_record(:connections, connection) do
    flags = flag(connection.boarding, 1) + flag(connection.alighting, 2)

    <<connection.departure_s::little-signed-32, connection.arrival_s::little-signed-32,
      connection.departure_stop::little-32, connection.arrival_stop::little-32,
      connection.trip::little-32, connection.sequence::little-16, flags::8, 0::8>>
  end

  defp encode_record(:positions, :unknown) do
    <<@position_unknown::little-signed-32, @position_unknown::little-signed-32>>
  end

  defp encode_record(:positions, %{lat_microdegrees: lat, lon_microdegrees: lon})
       when abs(lat) <= @lat_microdegrees_max and abs(lon) <= @lon_microdegrees_max do
    <<lat::little-signed-32, lon::little-signed-32>>
  end

  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0

  defp string(text) when is_binary(text) and byte_size(text) <= @string_bytes_max do
    <<byte_size(text)::little-16, text::binary>>
  end

  @doc "Returns the kind and the records of `file`, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, %{kind: kind(), records: list()}} | {:error, decode_error()}
  def decode(
        <<@magic, version::little-16, code::little-16, count::little-32, 0::little-32,
          body::binary>>
      ) do
    kind = Enum.find_value(@kinds, fn {kind, kind_code} -> if kind_code == code, do: kind end)

    cond do
      version != @version -> {:error, :unsupported_version}
      kind == nil -> {:error, :invalid_header}
      true -> decode_records(kind, body, count)
    end
  end

  def decode(file) when is_binary(file), do: {:error, :invalid_header}

  defp decode_records(kind, body, count) do
    case take(kind, body, count, []) do
      {:ok, records} -> {:ok, %{kind: kind, records: records}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp take(_kind, <<>>, 0, records), do: {:ok, Enum.reverse(records)}
  defp take(_kind, _rest, 0, _records), do: {:error, :invalid_length}

  defp take(kind, body, count, records) do
    case decode_record(kind, body) do
      {:ok, record, rest} -> take(kind, rest, count - 1, [record | records])
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_length}
    end
  end

  defp decode_record(:stops, body), do: read_string(body)

  defp decode_record(:trips, body) do
    with {:ok, id, rest} <- read_string(body),
         {:ok, route_id, <<offset::8, rest::binary>>} when offset in [0, 1] <- read_string(rest) do
      {:ok, %{id: id, route_id: route_id, service_day_offset: offset}, rest}
    else
      _other -> :error
    end
  end

  defp decode_record(
         :transfers,
         <<from::little-32, to::little-32, duration_s::little-32, rest::binary>>
       ) do
    {:ok, %{from_stop: from, to_stop: to, duration_s: duration_s}, rest}
  end

  defp decode_record(
         :connections,
         <<departure_s::little-signed-32, arrival_s::little-signed-32, departure_stop::little-32,
           arrival_stop::little-32, trip::little-32, sequence::little-16, flags::8, 0::8,
           rest::binary>>
       ) do
    connection = %{
      departure_s: departure_s,
      arrival_s: arrival_s,
      departure_stop: departure_stop,
      arrival_stop: arrival_stop,
      trip: trip,
      sequence: sequence,
      boarding: Bitwise.band(flags, 1) != 0,
      alighting: Bitwise.band(flags, 2) != 0
    }

    {:ok, connection, rest}
  end

  defp decode_record(
         :positions,
         <<@position_unknown::little-signed-32, @position_unknown::little-signed-32,
           rest::binary>>
       ) do
    {:ok, :unknown, rest}
  end

  defp decode_record(:positions, <<lat::little-signed-32, lon::little-signed-32, rest::binary>>)
       when abs(lat) <= @lat_microdegrees_max and abs(lon) <= @lon_microdegrees_max do
    {:ok, %{lat_microdegrees: lat, lon_microdegrees: lon}, rest}
  end

  defp decode_record(:positions, <<_position::binary-size(@position_bytes), _rest::binary>>) do
    {:error, :invalid_position}
  end

  defp decode_record(_kind, _body), do: :error

  defp read_string(<<length::little-16, text::binary-size(length), rest::binary>>) do
    if String.valid?(text), do: {:ok, text, rest}, else: :error
  end

  defp read_string(_body), do: :error
end
