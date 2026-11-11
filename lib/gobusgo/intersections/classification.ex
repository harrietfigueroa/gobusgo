defmodule Gobusgo.Intersections.Classification do
  @moduledoc """
  The `highway` classes whose named ways make crossings: motorway to
  residential, the links, `living_street`, and `pedestrian`, with
  `service` as a choice of the caller, since a service road is a driveway,
  a parking aisle, or an alley as often as a street. Everything here is
  pure.
  """

  @service "service"

  @classes [
    "motorway",
    "trunk",
    "primary",
    "secondary",
    "tertiary",
    "unclassified",
    "residential",
    "motorway_link",
    "trunk_link",
    "primary_link",
    "secondary_link",
    "tertiary_link",
    "living_street",
    "pedestrian"
  ]

  @doc "Whether the published build keeps `service` roads."
  @spec service_roads() :: boolean()
  def service_roads, do: false

  @doc "The `highway` values of the roads, with `service` where `service_roads` is true."
  @spec highway_classes(boolean()) :: [String.t()]
  def highway_classes(true), do: @classes ++ [@service]
  def highway_classes(false), do: @classes

  @doc "Whether the `highway` tag value `value` is one of the classes."
  @spec road?(String.t() | nil, boolean()) :: boolean()
  def road?(value, service_roads) when is_boolean(service_roads),
    do: value in highway_classes(service_roads)

  @doc "The `osmium tags-filter` expression that keeps the ways of the classes, a superset of what `road?/2` accepts."
  @spec tag_filter(boolean()) :: String.t()
  def tag_filter(service_roads) when is_boolean(service_roads),
    do: "w/highway=" <> Enum.join(highway_classes(service_roads), ",")
end
