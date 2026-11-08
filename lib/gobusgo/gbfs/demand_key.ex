defmodule Gobusgo.Gbfs.DemandKey do
  @shared_vehicles_dataset :shared_vehicles
  @shared_vehicles_item "all"

  @moduledoc """
  The key under which the shared vehicles are in demand in `Gobusgo.Demand`.
  Everything here is pure.

  Shared vehicles have the one key `shared_vehicles/0`, which a page holds
  while it shows the shared vehicle layer, so its count of holders is the
  count of the layer's viewers.
  """

  alias Gobusgo.Demand

  @doc "The datasets a registry has to admit to take the key of this module."
  @spec datasets() :: [atom(), ...]
  def datasets, do: [@shared_vehicles_dataset]

  @doc "The one key of the shared vehicles of every system."
  @spec shared_vehicles() :: Demand.key()
  def shared_vehicles, do: {@shared_vehicles_dataset, @shared_vehicles_item}
end
