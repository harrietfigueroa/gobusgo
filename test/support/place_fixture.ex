defmodule Gobusgo.Test.PlaceFixture do
  @moduledoc """
  The records of the shared places fixture under `test/fixtures/places/v1/`:
  `places.bin`, the expanded container, `places.bin.gz`, its gzip stream,
  and `expected.json`, the table a reader decodes from it. Five places cover
  ASCII and multibyte names, a name shared by two places, an alias list, no
  aliases, prominence and area at their 255 and 40 caps, a negative
  longitude, and the origin.
  """

  alias Gobusgo.Places.Classification
  alias Gobusgo.Places.Format
  alias Gobusgo.Places.Records

  @directory Path.expand("../fixtures/places/v1", __DIR__)
  @source_date "2026-11-08T21:21:00Z"

  @places [
    %{
      name: "Pike Place Market",
      aliases: ["The Market", "Public Market Center"],
      lat: 47.6097,
      lon: -122.3425,
      category: "tourism",
      prominence: 255,
      area: 20_000.0,
      area_score: 40
    },
    %{
      name: "Café Münster 東京",
      aliases: [],
      lat: 47.6,
      lon: -122.3,
      category: "food",
      prominence: 50,
      area: 0.0,
      area_score: 0
    },
    %{
      name: "Seattle Center",
      aliases: ["Center"],
      lat: 47.6205,
      lon: -122.3493,
      category: "park",
      prominence: 135,
      area: 900_000.0,
      area_score: 16
    },
    %{
      name: "Seattle Center",
      aliases: ["Monorail", "Center"],
      lat: 47.6143,
      lon: -122.3359,
      category: "station",
      prominence: 140,
      area: 0.0,
      area_score: 0
    },
    %{
      name: "Null Island",
      aliases: [],
      lat: 0.0,
      lon: 0.0,
      category: "place",
      prominence: 70,
      area: 0.0,
      area_score: 0
    }
  ]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The places the container holds."
  @spec places() :: [map()]
  def places, do: @places

  @doc "The source date the container holds."
  @spec source_date() :: String.t()
  def source_date, do: @source_date

  @doc "Returns the expanded container of the fixture places."
  @spec encode() :: binary()
  def encode, do: Format.encode(%{source_date: @source_date, places: @places})

  @doc "Returns the table a reader decodes from the container, as the JSON of `expected.json`."
  @spec expected() :: map()
  def expected do
    rows = Enum.map(@places, &Records.row/1)
    alias_counts = for [_name, aliases | _row] <- rows, do: length(aliases)
    alias_starts = Enum.scan(alias_counts, 0, &+/2)

    %{
      "placeCount" => length(rows),
      "names" => for([name | _row] <- rows, do: name),
      "aliasStarts" => [0 | alias_starts],
      "aliasNames" => for([_name, aliases | _row] <- rows, alias <- aliases, do: alias),
      "latitudeMicrodegrees" => for([_n, _a, lat | _row] <- rows, do: lat),
      "longitudeMicrodegrees" => for([_n, _a, _lat, lon | _row] <- rows, do: lon),
      "categories" => for([_n, _a, _lat, _lon, category | _row] <- rows, do: category),
      "prominences" => for([_n, _a, _lat, _lon, _c, prominence | _row] <- rows, do: prominence),
      "areas" => for([_n, _a, _lat, _lon, _c, _p, area] <- rows, do: area),
      "categoryNames" => Classification.categories(),
      "sourceDate" => @source_date
    }
  end
end
