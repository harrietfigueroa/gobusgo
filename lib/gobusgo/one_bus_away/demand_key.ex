defmodule Gobusgo.OneBusAway.DemandKey do
  @arrivals_dataset :arrivals
  @vehicles_dataset :vehicles
  @vehicles_item "all"

  @moduledoc """
  The keys under which the OneBusAway datasets are in demand in
  `Gobusgo.Demand`. Everything here is pure.

  Arrivals have one key per stop, `arrivals/1`, so the items of
  `arrivals_dataset/0` are the stops some process has open. Vehicles have
  the one key `vehicles/0`, so its count of holders is the count of
  processes that view vehicles.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Demand

  @doc "The datasets a registry has to admit to take every key of this module."
  @spec datasets() :: [atom(), ...]
  def datasets, do: [@arrivals_dataset, @vehicles_dataset]

  @doc "The dataset whose items are stop identifiers."
  @spec arrivals_dataset() :: atom()
  def arrivals_dataset, do: @arrivals_dataset

  @doc "The key of the arrivals at the stop `stop_id`, which must be non-empty."
  @spec arrivals(String.t()) :: Demand.key()
  def arrivals(stop_id) when is_binary(stop_id) do
    Assert.condition(stop_id != "", "stop identifier must be non-empty")
    {@arrivals_dataset, stop_id}
  end

  @doc "The one key of the vehicles of every agency."
  @spec vehicles() :: Demand.key()
  def vehicles, do: {@vehicles_dataset, @vehicles_item}
end
