defmodule GobusgoWeb.VehicleLive.SharedVehicles do
  @fetch_age_ms_max 180_000
  @zoom_min 14
  @range_low_meters 3_000
  @check_interval_ms 15_000
  @meters_per_kilometer 1_000

  @moduledoc """
  The shared vehicle layer of a vehicle page: the page's hold on the shared
  vehicles key, which is what has the shared vehicle source fetch, the
  indexes the browser draws the layer from, and what the page says of the
  layer.

  A page draws a system's vehicles from its current index of
  `Gobusgo.Gbfs.VehicleTiles` while that index's fetch is at most
  #{@fetch_age_ms_max} ms old, the oldest fetch GOB-259 settled on planning
  from; a page shows no older one, so a feed that stops answering hides the
  layer. A page that has just turned
  the layer on waits for a first fetch for one run deadline of
  `Gobusgo.Gbfs.VehicleStatusCycle` and one scheduler evaluation period
  before it says there is none. A page checks again every
  #{@check_interval_ms} ms while the layer is on.

  The layer is drawn from zoom #{@zoom_min}, where a phone's view spans a
  few of the tiles of `Gobusgo.Gbfs.VehicleTileSet` and the map of a
  neighborhood still reads, and a vehicle with less than
  #{@range_low_meters} m of range is drawn faded: the least range GOB-259
  settled on for a scooter leg, 1.5 times its 2 km ride, below which a
  vehicle takes a rider no useful distance. Each form factor has one color,
  which reads on the light map and on the dark one.

  The calling process holds the registration.
  """

  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.DemandKey
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusCycle
  alias Gobusgo.Gbfs.VehicleTiles
  alias Gobusgo.Scheduler

  @form_colors [
    %{form_factor: :standing_scooter, label: "Scooter", color: "#0f766e"},
    %{form_factor: :seated_scooter, label: "Seated scooter", color: "#7e22ce"},
    %{form_factor: :e_bike, label: "E-bike", color: "#c2410c"},
    %{form_factor: :bike, label: "Bike", color: "#1d4ed8"},
    %{form_factor: :other, label: "Other", color: "#64748b"}
  ]

  @type status :: :loading | :shown | :none

  @typedoc "An index a page hands the browser, with the operator it credits."
  @type shown_index :: %{url: String.t(), system_id: String.t(), operator_name: String.t()}

  @doc "The age past which a page draws no fetch, in milliseconds."
  @spec fetch_age_ms_max() :: pos_integer()
  def fetch_age_ms_max, do: @fetch_age_ms_max

  @doc "The zoom from which the browser draws the layer."
  @spec zoom_min() :: pos_integer()
  def zoom_min, do: @zoom_min

  @doc "The range below which the browser draws a vehicle faded, in meters."
  @spec range_low_meters() :: pos_integer()
  def range_low_meters, do: @range_low_meters

  @doc "How often a page with the layer on checks its indexes again, in milliseconds."
  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms, do: @check_interval_ms

  @doc "How long a page waits for a first fetch after turning the layer on, in milliseconds."
  @spec first_fetch_wait_ms() :: pos_integer()
  def first_fetch_wait_ms,
    do: VehicleStatusCycle.run_deadline_ms() + Scheduler.evaluation_period_ms()

  @doc "Each form factor's label and color, in display order."
  @spec form_colors() :: [%{form_factor: atom(), label: String.t(), color: String.t()}, ...]
  def form_colors, do: @form_colors

  @doc """
  Registers the shared vehicles key for the calling process: `:busy` when
  the registry refuses it or does not answer.
  """
  @spec hold() :: :ok | :busy
  def hold do
    case Demand.register(Demand, DemandKey.shared_vehicles()) do
      :ok -> :ok
      {:error, _bound_exceeded} -> :busy
    end
  catch
    :exit, _reason -> :busy
  end

  @doc "Ends the calling process's registration of the shared vehicles key."
  @spec release() :: :ok
  def release do
    Demand.release(Demand, DemandKey.shared_vehicles())
  catch
    # A registry that is down holds no registration to release.
    :exit, _reason -> :ok
  end

  @doc """
  The indexes of `Gobusgo.Gbfs.VehicleTiles` the page hands the browser at
  `now`; none while the process does not answer.
  """
  @spec indexes(DateTime.t()) :: [shown_index()]
  def indexes(%DateTime{} = now) do
    fresh_indexes(%{indexes: VehicleTiles.current(VehicleTiles), now: now})
  catch
    :exit, _reason -> []
  end

  @doc "The indexes of `input.indexes` whose fetch is fresh at `input.now`, as a page hands them over."
  @spec fresh_indexes(%{indexes: [VehicleTiles.index()], now: DateTime.t()}) :: [shown_index()]
  def fresh_indexes(%{indexes: indexes, now: %DateTime{} = now}) when is_list(indexes) do
    operator_names = Map.new(Systems.all(), &{&1.id, &1.operator_name})

    for %{system_id: system_id, destination: destination, fetched_at: fetched_at} <- indexes,
        DateTime.diff(now, fetched_at, :millisecond) <= @fetch_age_ms_max do
      %{
        url: "/" <> destination,
        system_id: system_id,
        operator_name: Map.get(operator_names, system_id, system_id)
      }
    end
  end

  @doc """
  What the page says of a layer that is on, with `indexes` to draw and
  turned on `shown_ms_ago` milliseconds before.
  """
  @spec status(%{indexes: [shown_index()], shown_ms_ago: non_neg_integer()}) :: status()
  def status(%{indexes: [_index | _rest]}), do: :shown

  def status(%{indexes: [], shown_ms_ago: shown_ms_ago}) when is_integer(shown_ms_ago) do
    if shown_ms_ago < first_fetch_wait_ms() do
      :loading
    else
      :none
    end
  end

  @doc "The sentence that says `status`."
  @spec status_text(status()) :: String.t()
  def status_text(:loading), do: "Loading shared scooters and bikes…"

  def status_text(:none),
    do: "No shared scooters or bikes to show: the operator's feed has no current data."

  def status_text(:shown) do
    range_low_km = div(@range_low_meters, @meters_per_kilometer)

    "Shown when the map is zoomed in to a neighborhood. Faded ones have under " <>
      "#{range_low_km} km of range."
  end
end
