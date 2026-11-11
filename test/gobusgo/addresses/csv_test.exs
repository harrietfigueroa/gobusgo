defmodule Gobusgo.Addresses.CsvTest do
  # Feeds hand-written CSV text to the reader cut into chunks of every size,
  # so a field, a quote, or a line break split across two chunks reads as it
  # does whole.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Assert.AssertionError

  defp rows_of(text, chunk_bytes) do
    text
    |> chunks(chunk_bytes)
    |> Csv.rows()
    |> Enum.to_list()
  end

  defp chunks(text, chunk_bytes) do
    for index <- 0..(byte_size(text) - 1)//chunk_bytes do
      binary_part(text, index, min(chunk_bytes, byte_size(text) - index))
    end
  end

  @cases [
    {"plain rows", "a,b,c\n1,2,3\n", [["a", "b", "c"], ["1", "2", "3"]]},
    {"no final line break", "a,b\n1,2", [["a", "b"], ["1", "2"]]},
    {"carriage return and line feed", "a,b\r\n1,2\r\n", [["a", "b"], ["1", "2"]]},
    {"empty fields", "a,,c\n,,\n", [["a", "", "c"], ["", "", ""]]},
    {"a trailing comma", "a,b,\n", [["a", "b", ""]]},
    {"a quoted comma", ~s("a,b",c\n), [["a,b", "c"]]},
    {"a quoted line break", "\"line one\nline two\",x\n", [["line one\nline two", "x"]]},
    {"a doubled quote", ~s("say ""hi""",x\n), [[~s(say "hi"), "x"]]},
    {"an empty quoted field", ~s(a,"",b\n), [["a", "", "b"]]},
    {"blank lines are no rows", "a\n\n\nb\n", [["a"], ["b"]]},
    {"a byte order mark is dropped", "﻿a,b\n", [["a", "b"]]},
    {"a quote inside an unquoted field is kept", ~s(5" pipe,x\n), [[~s(5" pipe), "x"]]},
    {"multibyte text", "ÅÄÖ,é\n", [["ÅÄÖ", "é"]]}
  ]

  for {name, text, expected} <- @cases, chunk_bytes <- [1, 2, 3, 7, 1_000] do
    @text text
    @expected expected
    @chunk_bytes chunk_bytes

    test "#{name}, in chunks of #{chunk_bytes} bytes" do
      assert rows_of(@text, @chunk_bytes) == @expected
    end
  end

  test "a row past the byte bound fails an assertion" do
    text = String.duplicate("a", 1_048_577) <> "\n"
    assert_raise AssertionError, fn -> rows_of(text, 65_536) end
  end

  test "a row past the field bound fails an assertion" do
    text = String.duplicate(",", 300) <> "\n"
    assert_raise AssertionError, fn -> rows_of(text, 65_536) end
  end

  describe "encode_row/1" do
    for {name, row, expected} <- [
          {"plain fields", ["a", "b", "c"], "a,b,c\n"},
          {"empty fields", ["a", "", "c"], "a,,c\n"},
          {"a comma", ["a,b", "c"], ~s("a,b",c\n)},
          {"a quote written twice", [~s(say "hi")], ~s("say ""hi"""\n)},
          {"a line break", ["one\ntwo", "x"], "\"one\ntwo\",x\n"},
          {"a carriage return", ["one\rtwo"], "\"one\rtwo\"\n"},
          {"multibyte text", ["Café", "x"], "Café,x\n"}
        ] do
      test "writes #{name} so the reader reads the row back" do
        row = unquote(Macro.escape(row))
        encoded = row |> Csv.encode_row() |> IO.iodata_to_binary()

        assert encoded == unquote(expected)
        assert rows_of(encoded, 3) == [row]
      end
    end
  end
end
