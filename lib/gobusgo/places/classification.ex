defmodule Gobusgo.Places.Classification do
  @moduledoc """
  The categories of the places file and the rules that put a tagged OSM
  feature in one, with the base prominence of each. Everything here is pure.

  The `osmium tags-filter` expressions of `tag_filters/0` select a superset
  of what `classify/1` accepts and live beside it, so a category added to
  one is added to the other.

  Transit stops and platforms are not places: `stop?/1` names them, and
  they come from the stop view. Stations are places.
  """

  @categories ~w(station hospital health education park leisure tourism food amenity shop office historic building place)

  @excluded_amenities MapSet.new(
                        ~w(parking parking_space parking_entrance bicycle_parking motorcycle_parking bench waste_basket waste_disposal vending_machine post_box telephone fire_hydrant recycling drinking_water toilets atm charging_station bicycle_rental grit_bin loading_dock shelter bbq fountain clock parcel_locker letter_box water_point hunting_stand compressed_air dog_toilet kneipp_water_cure smoking_area watering_place lounger picnic_table)
                      )
  @excluded_leisure MapSet.new(
                      ~w(picnic_table fitness_station firepit slipway swimming_pool outdoor_seating bleachers pitch_part track)
                    )
  @excluded_tourism MapSet.new(~w(information picnic_site camp_pitch))
  @place_bases %{
    "city" => 200,
    "town" => 170,
    "suburb" => 160,
    "quarter" => 160,
    "neighbourhood" => 150,
    "village" => 120,
    "island" => 90,
    "islet" => 40,
    "hamlet" => 70,
    "locality" => 70
  }
  @education_bases %{"university" => 150, "college" => 130, "school" => 90, "kindergarten" => 40}
  @leisure_bases %{"stadium" => 160, "sports_centre" => 70, "golf_course" => 70, "marina" => 70}
  @tourism_bases %{
    "attraction" => 140,
    "museum" => 130,
    "zoo" => 140,
    "aquarium" => 140,
    "theme_park" => 120,
    "hotel" => 70,
    "viewpoint" => 70,
    "gallery" => 70
  }
  @shop_bases %{"mall" => 120, "department_store" => 90, "supermarket" => 70}
  @food MapSet.new(~w(restaurant cafe fast_food bar pub ice_cream food_court biergarten))
  @health MapSet.new(~w(clinic doctors dentist pharmacy))
  @civic MapSet.new(
           ~w(library community_centre townhall courthouse ferry_terminal bus_station arts_centre theatre cinema marketplace police post_office events_venue conference_centre)
         )

  @station_base 140
  @hospital_base 150
  @health_base 50
  @park_base 80
  @leisure_base_default 50
  @tourism_base_default 50
  @food_base 50
  @civic_base 100
  @amenity_base_default 45
  @shop_base_default 40
  @retail_area_base 80
  @office_base 30
  @historic_base 50
  @building_base 30

  @tag_filters ~w(
    nwr/railway=station,halt
    nwr/public_transport=station
    nwr/aeroway=aerodrome,terminal
    nwr/amenity
    nwr/healthcare
    nwr/place=city,town,village,hamlet,suburb,quarter,neighbourhood,locality,island,islet
    nwr/leisure
    nwr/tourism
    nwr/shop
    nwr/landuse=retail,commercial
    nwr/boundary=national_park
    nwr/office
    nwr/historic
    nwr/building
  )

  @type tags :: %{optional(String.t()) => String.t()}
  @type classification :: {:ok, %{category: String.t(), base: non_neg_integer()}} | :excluded

  @doc "The category names in index order."
  @spec categories() :: [String.t(), ...]
  def categories, do: @categories

  @doc "The `osmium tags-filter` expressions that select every feature `classify/1` can accept."
  @spec tag_filters() :: [String.t(), ...]
  def tag_filters, do: @tag_filters

  @doc "Whether the tags name a transit stop or platform, which the stop view holds."
  @spec stop?(tags()) :: boolean()
  def stop?(tags) do
    highway_stop = tags["highway"] == "bus_stop"
    transit_stop = tags["public_transport"] in ["platform", "stop_position"]
    rail_stop = tags["railway"] in ["platform", "tram_stop", "stop"]
    highway_stop or transit_stop or rail_stop
  end

  @doc "The category and base prominence of a feature with these tags, or `:excluded`."
  @spec classify(tags()) :: classification()
  def classify(tags) when is_map(tags) do
    amenity = tags["amenity"]

    cond do
      station?(tags) ->
        found("station", @station_base)

      amenity == "hospital" or tags["healthcare"] == "hospital" ->
        found("hospital", @hospital_base)

      Map.has_key?(@place_bases, tags["place"]) ->
        found("place", @place_bases[tags["place"]])

      Map.has_key?(@education_bases, amenity) ->
        found("education", @education_bases[amenity])

      MapSet.member?(@health, amenity) or Map.has_key?(tags, "healthcare") ->
        found("health", @health_base)

      park?(tags) ->
        found("park", @park_base)

      listed?(tags, "leisure", @excluded_leisure) ->
        found("leisure", Map.get(@leisure_bases, tags["leisure"], @leisure_base_default))

      listed?(tags, "tourism", @excluded_tourism) ->
        found("tourism", Map.get(@tourism_bases, tags["tourism"], @tourism_base_default))

      MapSet.member?(@food, amenity) ->
        found("food", @food_base)

      listed?(tags, "amenity", @excluded_amenities) ->
        found("amenity", amenity_base(amenity))

      Map.has_key?(tags, "shop") ->
        found("shop", Map.get(@shop_bases, tags["shop"], @shop_base_default))

      retail_area?(tags) ->
        found("shop", @retail_area_base)

      Map.has_key?(tags, "office") ->
        found("office", @office_base)

      Map.has_key?(tags, "historic") ->
        found("historic", @historic_base)

      Map.has_key?(tags, "building") ->
        found("building", @building_base)

      true ->
        :excluded
    end
  end

  defp found(category, base), do: {:ok, %{category: category, base: base}}

  defp station?(tags) do
    railway_station = tags["railway"] in ["station", "halt"]
    transit_station = tags["public_transport"] == "station"
    bus_or_ferry = tags["amenity"] in ["bus_station", "ferry_terminal"]
    airport = tags["aeroway"] in ["aerodrome", "terminal"]
    railway_station or transit_station or bus_or_ferry or airport
  end

  defp park?(tags) do
    green = tags["leisure"] in ["park", "nature_reserve", "garden"]
    green or tags["boundary"] == "national_park"
  end

  # A key the feature carries whose value the category does not leave out.
  defp listed?(tags, key, excluded) do
    case Map.fetch(tags, key) do
      {:ok, value} -> not MapSet.member?(excluded, value)
      :error -> false
    end
  end

  defp amenity_base(amenity) do
    if MapSet.member?(@civic, amenity), do: @civic_base, else: @amenity_base_default
  end

  defp retail_area?(tags) do
    retail = tags["landuse"] in ["retail", "commercial"]
    retail and Map.has_key?(tags, "wikidata")
  end
end
