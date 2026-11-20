defmodule Gobusgo.WalkGraph.ClassificationTest do
  # Checks which ways are walkable and what class each is, as a table of tag
  # sets and the answer the rule gives, the exclusions among them.
  use ExUnit.Case, async: true

  alias Gobusgo.WalkGraph.Classification

  @walkable [
    {%{"highway" => "footway"}, :path},
    {%{"highway" => "path"}, :path},
    {%{"highway" => "pedestrian"}, :path},
    {%{"highway" => "track"}, :path},
    {%{"highway" => "footway", "footway" => "sidewalk"}, :sidewalk},
    {%{"highway" => "footway", "footway" => "crossing"}, :crossing},
    {%{"highway" => "footway", "crossing" => "marked"}, :crossing},
    {%{"highway" => "cycleway", "cycleway" => "crossing", "foot" => "yes"}, :crossing},
    {%{"highway" => "steps"}, :steps},
    {%{"highway" => "residential"}, :street},
    {%{"highway" => "service", "service" => "alley"}, :street},
    {%{"highway" => "tertiary"}, :street},
    {%{"highway" => "cycleway", "foot" => "designated"}, :path},
    {%{"highway" => "bridleway", "foot" => "permissive"}, :path},
    {%{"highway" => "trunk", "sidewalk" => "both"}, :street},
    {%{"highway" => "trunk_link", "foot" => "yes"}, :street},
    {%{"highway" => "trunk", "sidewalk:left" => "yes"}, :street},
    {%{"highway" => "trunk", "sidewalk:both" => "yes"}, :street},
    {%{"highway" => "corridor"}, :path},
    {%{"highway" => "elevator"}, :path},
    {%{"highway" => "service", "access" => "private", "foot" => "yes"}, :street}
  ]

  @excluded [
    {%{}, :not_highway},
    {%{"highway" => "motorway"}, :motorway},
    {%{"highway" => "motorway_link", "foot" => "yes"}, :motorway},
    {%{"highway" => "trunk"}, :needs_foot_permission},
    {%{"highway" => "trunk", "sidewalk" => "no"}, :needs_foot_permission},
    {%{"highway" => "trunk", "sidewalk" => "separate"}, :needs_foot_permission},
    {%{"highway" => "trunk", "sidewalk:left" => "no"}, :needs_foot_permission},
    {%{"highway" => "cycleway"}, :needs_foot_permission},
    {%{"highway" => "bridleway"}, :needs_foot_permission},
    {%{"highway" => "construction"}, :not_walkable_highway},
    {%{"highway" => "proposed"}, :not_walkable_highway},
    {%{"highway" => "raceway"}, :not_walkable_highway},
    {%{"highway" => "pedestrian", "area" => "yes"}, :area},
    {%{"highway" => "footway", "foot" => "no"}, :foot_forbidden},
    {%{"highway" => "residential", "foot" => "private"}, :foot_forbidden},
    {%{"highway" => "service", "access" => "private"}, :access_closed},
    {%{"highway" => "residential", "access" => "no"}, :access_closed}
  ]

  for {tags, class} <- @walkable do
    test "accepts #{inspect(tags)} as #{class}" do
      assert Classification.class(unquote(Macro.escape(tags))) == {:ok, unquote(class)}
    end
  end

  for {tags, reason} <- @excluded do
    test "excludes #{inspect(tags)} as #{reason}" do
      assert Classification.class(unquote(Macro.escape(tags))) == {:excluded, unquote(reason)}
    end
  end

  test "numbers the classes in the order the shard stores them" do
    assert Enum.map(Classification.classes(), &Classification.number/1) == [0, 1, 2, 3, 4]
  end

  test "the tag filter keeps every highway the rule can accept" do
    filter = Classification.tag_filter()
    accepted = for {%{"highway" => highway}, _class} <- @walkable, do: highway

    for highway <- accepted do
      assert filter =~ highway
    end

    refute filter =~ "motorway"
  end
end
