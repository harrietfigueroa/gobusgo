defmodule Gobusgo.Places.Words do
  @moduledoc """
  The words a place name is compared by, normalized exactly as the browser
  search normalizes them: decomposed with the combining marks dropped,
  lowercased, `&` read as `and`, apostrophes dropped, split on every run of
  characters that is neither a letter nor a digit, and `centre` and
  `theatre` read as `center` and `theater`. Everything here is pure.
  """

  @apostrophes ["'", "’"]
  @spellings %{"centre" => "center", "theatre" => "theater"}
  @separator ~r/[^\p{L}\p{N}]+/u
  @combining_mark ~r/\p{M}/u

  @doc "The normalized words of `text`, in order."
  @spec normalize(String.t()) :: [String.t()]
  def normalize(text) when is_binary(text) do
    decomposed = :unicode.characters_to_nfd_binary(text)
    unmarked = Regex.replace(@combining_mark, decomposed, "")

    folded =
      unmarked
      |> String.downcase()
      |> String.replace("&", " and ")
      |> String.replace(@apostrophes, "")

    words = Regex.split(@separator, folded, trim: true)
    for word <- words, do: Map.get(@spellings, word, word)
  end

  @doc "The normalized words of `text` joined with a space, the key two names are equal by."
  @spec key(String.t()) :: String.t()
  def key(text) when is_binary(text), do: text |> normalize() |> Enum.join(" ")
end
