defmodule Gobusgo.WalkGraph.Classification do
  @moduledoc """
  Which OpenStreetMap ways a person can walk, and what kind of way each is.
  Everything here is pure.

  `class/1` takes a way's tags and returns `{:ok, class}` or `{:excluded,
  reason}`. A way is walkable when its `highway` is a path, a sidewalk, a
  crossing, steps, or a street a pedestrian shares with traffic, and no tag
  forbids foot traffic:

    * `motorway` and `motorway_link` are never walkable.
    * `trunk` and `trunk_link` are walkable only where `foot` is `yes`,
      `designated`, or `permissive`, or `sidewalk` names a sidewalk, since a
      trunk road in a city is one that people cross and walk beside, and
      elsewhere one they must not walk on.
    * `cycleway` and `bridleway` are walkable only where `foot` is `yes`,
      `designated`, or `permissive`.
    * `foot=no` and `foot=private` exclude a way; `access=no` and
      `access=private` exclude it unless `foot` allows it.
    * A way with `area=yes` is a plaza's outline, not a line to walk along.
    * Every other `highway` value, `construction`, `proposed`, `corridor`,
      `elevator`, and `raceway` among them, is excluded.

  A walkable way is one of five classes, whose numbers the shard stores:
  `path`, `sidewalk`, `crossing`, `steps`, and `street`.
  """

  @classes %{path: 0, sidewalk: 1, crossing: 2, steps: 3, street: 4}

  @path_highways ["footway", "path", "pedestrian", "track", "platform"]
  @restricted_highways ["cycleway", "bridleway"]
  @street_highways [
    "living_street",
    "residential",
    "service",
    "unclassified",
    "tertiary",
    "tertiary_link",
    "secondary",
    "secondary_link",
    "primary",
    "primary_link"
  ]
  @trunk_highways ["trunk", "trunk_link"]
  @foot_allowed ["yes", "designated", "permissive"]
  @foot_forbidden ["no", "private"]
  @access_closed ["no", "private"]
  @sidewalk_values ["both", "left", "right", "yes"]
  @crossing_keys ["footway", "cycleway"]

  @type class :: :path | :sidewalk | :crossing | :steps | :street
  @type reason ::
          :not_highway
          | :not_walkable_highway
          | :motorway
          | :area
          | :foot_forbidden
          | :access_closed
          | :needs_foot_permission

  @doc "The number the shard stores for `class`."
  @spec number(class()) :: 0..4
  def number(class) when is_map_key(@classes, class), do: Map.fetch!(@classes, class)

  @doc "Every class, in number order."
  @spec classes() :: [class()]
  def classes, do: @classes |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  @doc "The class of the way whose tags are `tags`, or the reason it is excluded."
  @spec class(%{String.t() => String.t()}) :: {:ok, class()} | {:excluded, reason()}
  def class(tags) when is_map(tags) do
    highway = Map.get(tags, "highway")

    cond do
      is_nil(highway) -> {:excluded, :not_highway}
      highway in ["motorway", "motorway_link"] -> {:excluded, :motorway}
      not walkable_highway?(highway) -> {:excluded, :not_walkable_highway}
      Map.get(tags, "area") == "yes" -> {:excluded, :area}
      Map.get(tags, "foot") in @foot_forbidden -> {:excluded, :foot_forbidden}
      true -> permitted_class(highway, tags)
    end
  end

  defp walkable_highway?(highway) do
    highway in @path_highways or highway in @restricted_highways or highway in @street_highways or
      highway in @trunk_highways or highway == "steps"
  end

  defp permitted_class(highway, tags) do
    is_foot_allowed = Map.get(tags, "foot") in @foot_allowed
    is_access_closed = Map.get(tags, "access") in @access_closed
    is_restricted = highway in @restricted_highways
    is_trunk = highway in @trunk_highways
    has_sidewalk = Map.get(tags, "sidewalk") in @sidewalk_values
    is_trunk_walkable = is_foot_allowed or has_sidewalk

    cond do
      is_access_closed and not is_foot_allowed -> {:excluded, :access_closed}
      is_restricted and not is_foot_allowed -> {:excluded, :needs_foot_permission}
      is_trunk and not is_trunk_walkable -> {:excluded, :needs_foot_permission}
      true -> {:ok, class_of(highway, tags)}
    end
  end

  defp class_of("steps", _tags), do: :steps

  defp class_of(highway, tags) do
    is_street = highway in @street_highways or highway in @trunk_highways

    cond do
      is_street -> :street
      crossing?(tags) -> :crossing
      Map.get(tags, "footway") == "sidewalk" -> :sidewalk
      true -> :path
    end
  end

  defp crossing?(tags) do
    has_crossing_value = Enum.any?(@crossing_keys, &(Map.get(tags, &1) == "crossing"))
    has_crossing_tag = Map.has_key?(tags, "crossing")
    has_crossing_value or has_crossing_tag
  end

  @doc "The `osmium tags-filter` expression that keeps every way `class/1` may accept."
  @spec tag_filter() :: String.t()
  def tag_filter do
    highways =
      @path_highways ++ @restricted_highways ++ @street_highways ++ @trunk_highways ++ ["steps"]

    "w/highway=" <> Enum.join(highways, ",")
  end
end
