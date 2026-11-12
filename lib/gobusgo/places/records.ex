defmodule Gobusgo.Places.Records do
  @moduledoc """
  The places as the rows a places file is encoded from, and as the JSON text
  that shows them. Everything here is pure.

  A row is `[name, aliases, latitude, longitude, category_index, prominence,
  area, locality]` with the position in integer microdegrees, the category as
  its index in `Gobusgo.Places.Classification.categories/0`, `prominence` and
  `area` the two separate scores, never added, and `locality` the text of
  `Gobusgo.Places.Locality`, empty for a place with none.
  """

  alias Gobusgo.CanonicalJson
  alias Gobusgo.Places.Classification
  alias Gobusgo.Places.Selection

  @microdegrees_per_degree 1_000_000

  @type row :: [term(), ...]

  @doc "The row of one place."
  @spec row(Selection.candidate()) :: row()
  def row(place) do
    index = Enum.find_index(Classification.categories(), &(&1 == place.category))

    [
      place.name,
      place.aliases,
      round(place.lat * @microdegrees_per_degree),
      round(place.lon * @microdegrees_per_degree),
      index,
      place.prominence,
      place.area_score,
      place.locality
    ]
  end

  @doc "The JSON text of the source date, the category names, and the rows of `places`."
  @spec encode(%{source_date: String.t(), places: [Selection.candidate()]}) :: binary()
  def encode(%{source_date: source_date, places: places}) do
    CanonicalJson.encode(%{
      "sourceDate" => source_date,
      "categories" => Classification.categories(),
      "places" => Enum.map(places, &row/1)
    })
  end
end
