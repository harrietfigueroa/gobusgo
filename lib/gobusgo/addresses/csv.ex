defmodule Gobusgo.Addresses.Csv do
  @row_bytes_max 1_048_576
  @field_count_max 256
  @byte_order_mark <<0xEF, 0xBB, 0xBF>>
  @unquoted_specials [",", "\n", "\r"]

  @moduledoc """
  A streaming reader of CSV as RFC 4180 writes it: fields separated by
  commas, rows by line feeds or carriage return and line feed, a field in
  double quotes may hold commas, line breaks, and a quote written twice. A
  byte order mark at the start is dropped.

  `rows/1` takes a stream of binaries cut anywhere, a quoted field and a
  line break included, and returns a stream of rows, each a list of
  binaries, so no stage holds more than one chunk and one row. A row longer
  than #{@row_bytes_max} bytes or with more than #{@field_count_max} fields
  fails an assertion, which bounds what a malformed file can make the reader
  hold. A blank line is not a row. Everything here is pure.
  """

  alias Gobusgo.Assert

  @type row :: [binary()]

  @typep mode :: :start | :unquoted | :quoted | :quote_seen
  @typep state :: %{
           mode: mode(),
           field: iodata(),
           fields: [binary()],
           row_bytes: non_neg_integer(),
           first_row: boolean()
         }

  @doc """
  `row` written as one CSV row ending in a line feed, a field that holds a
  comma, a quote, or a line break in double quotes with each quote written
  twice, so `rows/1` reads the row back as it is.
  """
  @spec encode_row([binary()]) :: iodata()
  def encode_row(row) when is_list(row) do
    [Enum.intersperse(Enum.map(row, &encode_field/1), ?,), ?\n]
  end

  defp encode_field(field) when is_binary(field) do
    needs_quotes = String.contains?(field, [",", "\"", "\n", "\r"])

    if needs_quotes do
      [?", String.replace(field, "\"", "\"\""), ?"]
    else
      field
    end
  end

  @doc "The rows of the CSV that `chunks` holds."
  @spec rows(Enumerable.t()) :: Enumerable.t()
  def rows(chunks) do
    Stream.transform(chunks, &init/0, &feed/2, &finish/1, fn _state -> :ok end)
  end

  defp init do
    %{mode: :start, field: [], fields: [], row_bytes: 0, first_row: true}
  end

  defp feed(chunk, state) when is_binary(chunk) do
    {rows, state} = scan(chunk, state, [])
    {rows, state}
  end

  defp finish(%{mode: :start, fields: []} = state), do: {[], state}

  defp finish(state) do
    {row, _state} = end_row(state)
    {[row], state}
  end

  # `rows` collects the finished rows, newest first.
  @spec scan(binary(), state(), [row()]) :: {[row()], state()}
  defp scan(<<>>, state, rows), do: {Enum.reverse(rows), state}

  defp scan(chunk, %{mode: :start} = state, rows) do
    case chunk do
      <<?", rest::binary>> ->
        scan(rest, %{state | mode: :quoted}, rows)

      <<?,, rest::binary>> ->
        scan(rest, push_field(state), rows)

      <<?\n, rest::binary>> ->
        scan_after_row(rest, state, rows)

      <<?\r, rest::binary>> ->
        scan(rest, state, rows)

      _other ->
        scan(chunk, %{state | mode: :unquoted}, rows)
    end
  end

  defp scan(chunk, %{mode: :unquoted} = state, rows) do
    case :binary.match(chunk, @unquoted_specials) do
      :nomatch ->
        scan(<<>>, take(state, chunk), rows)

      {position, 1} ->
        <<run::binary-size(^position), special, rest::binary>> = chunk
        state = take(state, run)

        case special do
          ?, -> scan(rest, push_field(state), rows)
          ?\n -> scan_after_row(rest, state, rows)
          ?\r -> scan(rest, state, rows)
        end
    end
  end

  defp scan(chunk, %{mode: :quoted} = state, rows) do
    case :binary.match(chunk, "\"") do
      :nomatch ->
        scan(<<>>, take(state, chunk), rows)

      {position, 1} ->
        <<run::binary-size(^position), ?", rest::binary>> = chunk
        scan(rest, %{take(state, run) | mode: :quote_seen}, rows)
    end
  end

  defp scan(chunk, %{mode: :quote_seen} = state, rows) do
    case chunk do
      <<?", rest::binary>> ->
        scan(rest, %{take(state, "\"") | mode: :quoted}, rows)

      <<?,, rest::binary>> ->
        scan(rest, push_field(state), rows)

      <<?\n, rest::binary>> ->
        scan_after_row(rest, state, rows)

      <<?\r, rest::binary>> ->
        scan(rest, state, rows)

      _other ->
        scan(chunk, %{state | mode: :unquoted}, rows)
    end
  end

  defp scan_after_row(rest, state, rows) do
    is_blank = state.fields == [] and state.field == []

    if is_blank do
      scan(rest, %{state | mode: :start, row_bytes: 0}, rows)
    else
      {row, state} = end_row(state)
      scan(rest, state, [row | rows])
    end
  end

  defp take(state, bytes) do
    row_bytes = state.row_bytes + byte_size(bytes)

    Assert.condition(
      row_bytes <= @row_bytes_max,
      "a CSV row is at most #{@row_bytes_max} bytes"
    )

    %{state | field: [bytes | state.field], row_bytes: row_bytes}
  end

  defp push_field(state) do
    field = state.field |> Enum.reverse() |> IO.iodata_to_binary()
    fields = [field | state.fields]

    Assert.condition(
      length(fields) <= @field_count_max,
      "a CSV row has at most #{@field_count_max} fields"
    )

    %{state | mode: :start, field: [], fields: fields, row_bytes: state.row_bytes + 1}
  end

  defp end_row(state) do
    state = push_field(state)
    row = without_byte_order_mark(Enum.reverse(state.fields), state.first_row)

    {row, %{state | mode: :start, fields: [], row_bytes: 0, first_row: false}}
  end

  # The mark is three bytes, so it can arrive split across chunks; it is
  # dropped from the first field of the first row, where it always sits.
  defp without_byte_order_mark([@byte_order_mark <> first | rest], true), do: [first | rest]
  defp without_byte_order_mark(row, _is_first_row), do: row
end
