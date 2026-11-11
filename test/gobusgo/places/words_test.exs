defmodule Gobusgo.Places.WordsTest do
  # Checks the words a name is compared by against the cases the browser
  # search shares through test/fixtures/places/normalized_words.json, so the
  # two normalizations cannot drift.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Words

  @cases "test/fixtures/places/normalized_words.json"
         |> File.read!()
         |> JSON.decode!()
         |> Enum.map(&{&1["text"], &1["words"]})

  for {text, words} <- @cases do
    test "normalizes #{inspect(text)}" do
      assert Words.normalize(unquote(text)) == unquote(words)
    end
  end

  test "key joins the words with a space" do
    assert Words.key("Pike & Pine") == "pike and pine"
  end
end
