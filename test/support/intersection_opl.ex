defmodule Gobusgo.Test.IntersectionOpl do
  @moduledoc """
  A hand-written export of osmium's OPL format for the intersection tests,
  with the nodes first as osmium writes them. Pine Street crosses 3rd Avenue
  at two nodes 17 m apart (a dual carriageway) and 4th Avenue at one, one
  more node of the crossing of Pine and 3rd lies outside the test bounds,
  and Pine Street is split in two ways at 4th Avenue. A service road named
  "Parking Aisle" passes through the first node, a footway and an unnamed
  road pass through others, and "Café Row" is a name outside the supported
  alphabet.
  """

  @bounds %{south: 47.0, west: -123.0, north: 48.0, east: -122.0}

  @lines [
    "n1 T x-122.3371 y47.6107",
    "n2 Thighway=traffic_signals x-122.3356 y47.6112",
    "n3 T x-122.3340 y47.6120",
    "n4 T x-122.3380 y47.6100",
    "n5 T x-122.3350 y47.6130",
    "n6 T x-100.0 y40.0",
    "n7 T x-122.3373 y47.6108",
    "n8 T x-122.3300 y47.6200",
    "w10 Thighway=residential,name=Pine%20%Street Nn1,n7,n2,n3",
    "w11 Thighway=residential,name=3rd%20%Avenue Nn1,n4",
    "w12 Thighway=secondary,name=4th%20%Avenue Nn5,n2",
    "w13 Thighway=residential,name=Pine%20%Street Nn2,n6",
    "w14 Thighway=service,service=parking_aisle,name=Parking%20%Aisle Nn1,n8",
    "w15 Thighway=footway,name=Waterfront%20%Trail Nn1,n8",
    "w16 Thighway=residential Nn1,n8",
    "w17 Thighway=residential,name=Caf%e9%%20%Row Nn1,n8",
    "w18 Thighway=residential,name=Third%20%Avenue Nn7,n8",
    "w19 Thighway=residential,name=3rd%20%Avenue Nn6,n8"
  ]

  @doc "The bounds the test export is read inside."
  @spec bounds() :: Gobusgo.Places.Bounds.t()
  def bounds, do: @bounds

  @doc "The lines of the export."
  @spec lines() :: [String.t()]
  def lines, do: @lines

  @doc "The lines of the export as the function the selection takes."
  @spec lines_fun() :: (-> [String.t()])
  def lines_fun, do: fn -> @lines end
end
