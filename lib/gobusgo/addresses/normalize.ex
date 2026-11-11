defmodule Gobusgo.Addresses.Normalize do
  @token_count_max 24
  @ordinal_digit_count_max 9
  @teen_min 11
  @teen_max 13
  @hundred 100

  @directions %{
    "N" => "N",
    "NORTH" => "N",
    "S" => "S",
    "SOUTH" => "S",
    "E" => "E",
    "EAST" => "E",
    "W" => "W",
    "WEST" => "W",
    "NE" => "NE",
    "NORTHEAST" => "NE",
    "NW" => "NW",
    "NORTHWEST" => "NW",
    "SE" => "SE",
    "SOUTHEAST" => "SE",
    "SW" => "SW",
    "SOUTHWEST" => "SW"
  }

  @compound_directions %{
    "NORTH EAST" => "NE",
    "NORTH WEST" => "NW",
    "SOUTH EAST" => "SE",
    "SOUTH WEST" => "SW"
  }

  # USPS Publication 28, appendix C1, for the types the counties use; "LP",
  # which Pierce County writes, is a loop.
  # https://pe.usps.com/text/pub28/28apc_002.htm — checked 2026-11-10
  @street_types %{
    "ALLEY" => "ALY",
    "ALY" => "ALY",
    "AVENUE" => "AVE",
    "AVE" => "AVE",
    "AV" => "AVE",
    "AVEN" => "AVE",
    "AVN" => "AVE",
    "BOULEVARD" => "BLVD",
    "BLVD" => "BLVD",
    "BL" => "BLVD",
    "CIRCLE" => "CIR",
    "CIR" => "CIR",
    "COURT" => "CT",
    "CT" => "CT",
    "CRESCENT" => "CRES",
    "CRES" => "CRES",
    "CREST" => "CRST",
    "CRST" => "CRST",
    "DRIVE" => "DR",
    "DR" => "DR",
    "EXPRESSWAY" => "EXPY",
    "EXPY" => "EXPY",
    "FREEWAY" => "FWY",
    "FWY" => "FWY",
    "HIGHWAY" => "HWY",
    "HWY" => "HWY",
    "KEY" => "KY",
    "KY" => "KY",
    "LANE" => "LN",
    "LN" => "LN",
    "LOOP" => "LOOP",
    "MALL" => "MALL",
    "PARKWAY" => "PKWY",
    "PKWY" => "PKWY",
    "PKY" => "PKWY",
    "PLACE" => "PL",
    "PL" => "PL",
    "POINT" => "PT",
    "PT" => "PT",
    "ROAD" => "RD",
    "RD" => "RD",
    "ROW" => "ROW",
    "SQUARE" => "SQ",
    "SQ" => "SQ",
    "STREET" => "ST",
    "ST" => "ST",
    "STR" => "ST",
    "TERRACE" => "TER",
    "TER" => "TER",
    "TRAIL" => "TRL",
    "TRL" => "TRL",
    "WALK" => "WALK",
    "WAY" => "WAY",
    "WY" => "WAY",
    "VIEW" => "VW",
    "VW" => "VW",
    "PARK" => "PARK",
    "PLAZA" => "PLZ",
    "PLZ" => "PLZ",
    "TUNNEL" => "TUNL",
    "TUNL" => "TUNL",
    "VISTA" => "VIS",
    "VIS" => "VIS",
    "RUN" => "RUN",
    "PATH" => "PATH",
    "RIDGE" => "RDG",
    "RDG" => "RDG",
    "COVE" => "CV",
    "CV" => "CV",
    "EXTENSION" => "EXT",
    "EXT" => "EXT",
    "BRIDGE" => "BRG",
    "BRG" => "BRG",
    "CENTER" => "CTR",
    "CTR" => "CTR",
    "RANCH" => "RNCH",
    "RNCH" => "RNCH",
    "ROUTE" => "RTE",
    "RTE" => "RTE",
    "LP" => "LOOP"
  }

  # Pierce County's "112TH ST CT E": a court, place, or loop off a numbered
  # street or avenue, whose type is the two words.
  @compound_type_firsts ["ST", "AVE", "LN"]
  @compound_type_seconds ["CT", "PL", "LOOP", "CIR", "RD"]

  # A numbered highway: a designator, whose spellings all key as "HWY", and a
  # whole number that is the route's number, not an ordinal.
  @highway_key "HWY"
  @highway_designators ["HWY", "HIGHWAY", "SR"]
  @state_route_words ["ROUTE", "RTE", "HIGHWAY", "HWY"]
  @route_number_pattern ~r/\A\d{1,#{@ordinal_digit_count_max}}\z/

  @ordinal_words %{
    "FIRST" => 1,
    "SECOND" => 2,
    "THIRD" => 3,
    "FOURTH" => 4,
    "FIFTH" => 5,
    "SIXTH" => 6,
    "SEVENTH" => 7,
    "EIGHTH" => 8,
    "NINTH" => 9,
    "TENTH" => 10,
    "ELEVENTH" => 11,
    "TWELFTH" => 12,
    "THIRTEENTH" => 13,
    "FOURTEENTH" => 14,
    "FIFTEENTH" => 15,
    "SIXTEENTH" => 16,
    "SEVENTEENTH" => 17,
    "EIGHTEENTH" => 18,
    "NINETEENTH" => 19,
    "TWENTIETH" => 20,
    "THIRTIETH" => 30,
    "FORTIETH" => 40,
    "FIFTIETH" => 50,
    "SIXTIETH" => 60,
    "SEVENTIETH" => 70,
    "EIGHTIETH" => 80,
    "NINETIETH" => 90,
    "HUNDREDTH" => 100
  }

  @unit_designators ~w(APT APARTMENT UNIT STE SUITE BLDG BUILDING FL FLOOR RM ROOM SPC SPACE LOT # NO)
  @intersection_words ["&", "AND", "AT", "@", "/"]
  @ordinal_pattern ~r/\A(\d{1,#{@ordinal_digit_count_max}})(ST|ND|RD|TH)?\z/
  @house_number_pattern ~r/\A(\d{1,#{@ordinal_digit_count_max}})([A-Z])?\z/
  @zip_pattern ~r/\A\d{5}\z/

  @moduledoc """
  The normalization of street addresses that the index build and the
  browser's search share, so a name a rider types and a name a county
  publishes reach one key. Everything here is pure, and
  `assets/js/address_normalize.js` holds the same rules for the browser: the
  two read the cases of `test/fixtures/addresses/normalize.json` and must
  reach the same result for each.

  A street is four parts: a prefix directional, a name, a type, and a suffix
  directional, each in the USPS abbreviation of Publication 28 where it has
  one. A numbered name is written as its digits with the ordinal suffix the
  number takes (`"12TH"`, `"1ST"`, `"22ND"`), whether it was typed as `"12"`,
  `"12th"`, or `"twelfth"`; a token of more than #{@ordinal_digit_count_max}
  digits is left as it is. A name that opens with `HWY`, `HIGHWAY`, `SR`, or
  `STATE ROUTE` (`RTE`, `HIGHWAY`, and `HWY` also read after `STATE`) and a
  whole number is a numbered highway keyed `"HWY"` and the number as it is,
  so `"HIGHWAY 99"`, `"SR 99"`, and `"State Route 99"` are one street and its
  number is not an ordinal.

  A text is cut into at most #{@token_count_max} tokens. A suffix directional
  and a type are read from the end of a street and a prefix directional from
  the start, each only while a name token remains. A two-word directional
  such as "NORTH EAST" merges only where two tokens follow it.
  """

  alias Gobusgo.Assert

  @type street :: %{
          pre_direction: String.t(),
          name: String.t(),
          type: String.t(),
          suf_direction: String.t()
        }

  @type query ::
          %{
            kind: :address,
            number: non_neg_integer(),
            number_suffix: String.t(),
            street: street(),
            locality: String.t(),
            zip: String.t()
          }
          | %{
              kind: :intersection,
              first: street(),
              second: street(),
              locality: String.t(),
              zip: String.t()
            }
          | %{kind: :street, street: street(), locality: String.t(), zip: String.t()}

  @doc "The most tokens `tokenize/1` keeps."
  @spec token_count_max() :: pos_integer()
  def token_count_max, do: @token_count_max

  @doc """
  A name token as its ordinal (`"12"`, `"12TH"`, and `"TWELFTH"` are all
  `"12TH"`), or the token unchanged.
  """
  @spec ordinal_token(String.t()) :: String.t()
  def ordinal_token(token) when is_binary(token) do
    case Map.fetch(@ordinal_words, token) do
      {:ok, number} ->
        Integer.to_string(number) <> ordinal_suffix(number)

      :error ->
        case Regex.run(@ordinal_pattern, token) do
          [_token, digits | _suffix] ->
            number = String.to_integer(digits)
            Integer.to_string(number) <> ordinal_suffix(number)

          nil ->
            token
        end
    end
  end

  defp ordinal_suffix(number) do
    last_two = rem(number, @hundred)
    is_teen = last_two >= @teen_min and last_two <= @teen_max

    cond do
      is_teen -> "TH"
      rem(number, 10) == 1 -> "ST"
      rem(number, 10) == 2 -> "ND"
      rem(number, 10) == 3 -> "RD"
      true -> "TH"
    end
  end

  @doc """
  The tokens of `text`: upper case, punctuation dropped, but `&`, `/`, `@`,
  `#`, and `,` kept as tokens of their own.
  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.upcase()
    |> then(&Regex.replace(~r/[&\/@#,]/, &1, " \\0 "))
    |> then(&Regex.replace(~r/[.'’"()]/u, &1, ""))
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.take(@token_count_max)
  end

  @doc """
  The four parts of a street from its tokens, in the order a sign or a
  county writes them.
  """
  @spec parse_street([String.t()]) :: street()
  def parse_street(raw_tokens) when is_list(raw_tokens) do
    Assert.condition(
      length(raw_tokens) <= @token_count_max,
      "at most #{@token_count_max} tokens, got: #{length(raw_tokens)}"
    )

    tokens = merge_compound_directions(raw_tokens)
    {suf_direction, tokens} = take_last_direction(tokens)
    {type, tokens} = take_type(tokens)
    {type, tokens} = take_compound_type(type, tokens)
    {pre_direction, tokens} = take_first_direction(tokens)

    %{
      pre_direction: pre_direction,
      name: name_from_tokens(tokens),
      type: type,
      suf_direction: suf_direction
    }
  end

  # "HIGHWAY 99", "HWY 99", "SR 99", and "STATE ROUTE 99" are one street, and
  # the 99 is a route number, so only the tokens after it are read as ordinals.
  defp name_from_tokens(tokens) do
    case take_highway(tokens) do
      {:ok, number, rest} ->
        ordinals = Enum.map(rest, &ordinal_token/1)
        Enum.join([@highway_key, number | ordinals], " ")

      :error ->
        Enum.map_join(tokens, " ", &ordinal_token/1)
    end
  end

  defp take_highway([designator, number | rest]) when designator in @highway_designators do
    take_route_number(number, rest)
  end

  defp take_highway(["STATE", word, number | rest]) when word in @state_route_words do
    take_route_number(number, rest)
  end

  defp take_highway(_tokens), do: :error

  defp take_route_number(number, rest) do
    if Regex.match?(@route_number_pattern, number) do
      {:ok, number, rest}
    else
      :error
    end
  end

  # "NORTH EAST 45TH STREET" is NE 45TH ST, while "NORTH WEST AVENUE" is N
  # WEST AVE: a two-word directional is merged only where two tokens follow
  # it. The list holds at most `@token_count_max` tokens, which bounds the
  # recursion.
  defp merge_compound_directions([first, second, third, fourth | rest]) do
    case Map.fetch(@compound_directions, first <> " " <> second) do
      {:ok, compound} ->
        [compound | merge_compound_directions([third, fourth | rest])]

      :error ->
        [first | merge_compound_directions([second, third, fourth | rest])]
    end
  end

  defp merge_compound_directions(tokens), do: tokens

  defp take_last_direction(tokens) when length(tokens) >= 2 do
    {init, [last]} = Enum.split(tokens, -1)

    case Map.fetch(@directions, last) do
      {:ok, direction} -> {direction, init}
      :error -> {"", tokens}
    end
  end

  defp take_last_direction(tokens), do: {"", tokens}

  defp take_type(tokens) when length(tokens) >= 2 do
    {init, [last]} = Enum.split(tokens, -1)

    case Map.fetch(@street_types, last) do
      {:ok, type} -> {type, init}
      :error -> {"", tokens}
    end
  end

  defp take_type(tokens), do: {"", tokens}

  defp take_compound_type(type, tokens) when type != "" and length(tokens) >= 2 do
    {init, [last]} = Enum.split(tokens, -1)
    first_type = Map.get(@street_types, last)
    is_compound = first_type in @compound_type_firsts and type in @compound_type_seconds

    if is_compound do
      {first_type <> " " <> type, init}
    else
      {type, tokens}
    end
  end

  defp take_compound_type(type, tokens), do: {type, tokens}

  defp take_first_direction([first | rest] = tokens) when rest != [] do
    case Map.fetch(@directions, first) do
      {:ok, direction} -> {direction, rest}
      :error -> {"", tokens}
    end
  end

  defp take_first_direction(tokens), do: {"", tokens}

  @doc """
  The street of a county's separate fields, joined into one line and parsed
  as a typed street is, so a county that writes "WEST" in the name and a
  rider who types "W" before it reach one street.
  """
  @spec street_from_fields(street()) :: street()
  def street_from_fields(%{
        pre_direction: pre_direction,
        name: name,
        type: type,
        suf_direction: suf_direction
      }) do
    [pre_direction, name, type, suf_direction]
    |> Enum.join(" ")
    |> tokenize()
    |> parse_street()
  end

  @doc "The one-line key of a street: its four parts, separated by spaces, empty parts left out."
  @spec street_key(street()) :: String.t()
  def street_key(%{} = street) do
    [street.pre_direction, street.name, street.type, street.suf_direction]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @doc "The street's name with its spaces removed, the key a shard is chosen by."
  @spec name_key(street()) :: String.t()
  def name_key(%{name: name}), do: String.replace(name, " ", "")

  @doc """
  What a rider typed, as one of three kinds: an address with a house number
  and a street, an intersection of two streets, or a street alone. A unit or
  suite is dropped; text after a comma is the locality, and a five-digit
  token there is a ZIP code.
  """
  @spec parse_query(String.t()) :: query()
  def parse_query(text) when is_binary(text) do
    tokens = tokenize(text)
    {street_tokens, locality_tokens} = split_locality(tokens)
    {zips, locality_kept} = Enum.split_with(locality_tokens, &Regex.match?(@zip_pattern, &1))
    zip = List.last(zips, "")
    locality = Enum.join(locality_kept, " ")
    kept = drop_unit(street_tokens)

    case intersection_index(kept) do
      {:ok, index} ->
        {first, [_word | second]} = Enum.split(kept, index)

        %{
          kind: :intersection,
          first: parse_street(first),
          second: parse_street(second),
          locality: locality,
          zip: zip
        }

      :error ->
        address_or_street(%{kept: kept, locality: locality, zip: zip})
    end
  end

  defp address_or_street(%{kept: kept, locality: locality, zip: zip}) do
    case kept do
      [first | [_street_token | _rest] = street_tokens] ->
        case Regex.run(@house_number_pattern, first) do
          [_token, digits | suffix] ->
            %{
              kind: :address,
              number: String.to_integer(digits),
              number_suffix: List.first(suffix, ""),
              street: parse_street(street_tokens),
              locality: locality,
              zip: zip
            }

          nil ->
            %{kind: :street, street: parse_street(kept), locality: locality, zip: zip}
        end

      _other ->
        %{kind: :street, street: parse_street(kept), locality: locality, zip: zip}
    end
  end

  defp split_locality(tokens) do
    case Enum.split_while(tokens, &(&1 != ",")) do
      {street_tokens, []} ->
        {street_tokens, []}

      {street_tokens, [_comma | after_comma]} ->
        {street_tokens, Enum.filter(after_comma, &locality_token?/1)}
    end
  end

  defp locality_token?(token), do: token not in [",", "WA", "WASHINGTON"]

  # The designator and the one token after it name the unit.
  defp drop_unit([]), do: []

  defp drop_unit([designator | rest]) when designator in @unit_designators,
    do: drop_unit(Enum.drop(rest, 1))

  defp drop_unit([token | rest]), do: [token | drop_unit(rest)]

  # An intersection word is read between two streets, never first or last.
  defp intersection_index(kept) do
    last_index = length(kept) - 1

    found =
      kept
      |> Enum.with_index()
      |> Enum.find(fn {token, index} ->
        index >= 1 and index < last_index and token in @intersection_words
      end)

    case found do
      {_token, index} -> {:ok, index}
      nil -> :error
    end
  end
end
