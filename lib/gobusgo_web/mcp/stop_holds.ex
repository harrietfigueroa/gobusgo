defmodule GobusgoWeb.Mcp.StopHolds do
  @hold_count_max 10

  @moduledoc """
  The stops MCP clients have the arrival source fetch. A hold is a process
  of its own that registers the stop's arrivals key of
  `Gobusgo.OneBusAway.DemandKey` in `Gobusgo.Demand`, as a vehicle page
  does when it opens the stop, and ends after `Gobusgo.OneBusAway.Sources.vehicle_hold_ms/0`,
  the time a page that goes away leaves its demand behind. The registry
  frees a key when its holder exits, so an ended hold needs no release. A
  hold per process keeps each one inside the registry's bound on the keys
  one process holds.

  At most #{@hold_count_max} stops are held at once, the capacity of the
  hold supervisor. The arrival source makes one request every
  `Gobusgo.OneBusAway.Sources.arrival_interval_ms/0` whatever is held, so
  the holds cannot raise the request rate, and a new stop waits for its
  first fetch behind at most the other holds: a test asserts that one
  request per held stop fits inside a hold. Asking again for a held stop
  renews its hold.

  Under the supervisor run a `Registry` that names each hold by its stop
  and the `DynamicSupervisor` that bounds them.
  """

  use Supervisor

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.Mcp.StopHolds.Hold

  @registry GobusgoWeb.Mcp.StopHolds.Registry
  @holds GobusgoWeb.Mcp.StopHolds.Holds

  @typedoc """
    * `:held` — the stop is held, newly or renewed.
    * `:cap_reached` — the capacity is used, or the demand registry has no
      room for the stop, and the stop is not held.
    * `:unavailable` — the demand registry does not answer.
  """
  @type outcome :: :held | :cap_reached | :unavailable

  @doc "The most stops MCP clients hold at once."
  @spec hold_count_max() :: pos_integer()
  def hold_count_max, do: @hold_count_max

  @doc "How long a hold lasts, in milliseconds."
  @spec hold_ms() :: pos_integer()
  def hold_ms, do: Sources.vehicle_hold_ms()

  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(options) when is_list(options) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.take(options, [:name]))
  end

  @doc """
  Holds the stop `stop_id` for `hold_ms` milliseconds from now, replacing
  the time left of a hold it has.
  """
  @spec hold(String.t(), %{hold_ms: pos_integer()}) :: outcome()
  def hold(stop_id, %{hold_ms: hold_ms}) when is_binary(stop_id) and is_integer(hold_ms) do
    live = for {pid, _value} <- Registry.lookup(@registry, stop_id), Process.alive?(pid), do: pid

    case live do
      [pid] ->
        :ok = Hold.renew(pid, hold_ms)
        :held

      [] ->
        start(%{stop_id: stop_id, hold_ms: hold_ms})
    end
  end

  # The supervisor refuses a start at its capacity before it looks at the
  # name, so a stop that is held is renewed before this is reached.
  defp start(%{stop_id: stop_id, hold_ms: hold_ms}) do
    spec = {Hold, %{stop_id: stop_id, hold_ms: hold_ms, registry: @registry}}

    case DynamicSupervisor.start_child(@holds, spec) do
      {:ok, _pid} ->
        :held

      {:error, {:already_started, pid}} ->
        :ok = Hold.renew(pid, hold_ms)
        :held

      # The hold process ignores its start when the demand registry refuses
      # the key, which only a bound on the registry does.
      :ignore ->
        :cap_reached

      {:error, :max_children} ->
        :cap_reached

      {:error, _reason} ->
        :unavailable
    end
  end

  @doc "The stops held now, in identifier order."
  @spec held_stop_ids() :: [String.t()]
  def held_stop_ids do
    # The registry drops the name of a process that exited a moment later,
    # so a hold that has ended is filtered by its process.
    held = Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    Enum.sort(for {stop_id, pid} <- held, Process.alive?(pid), do: stop_id)
  end

  @doc "Ends the hold of `stop_id`, whether or not there is one."
  @spec release(String.t()) :: :ok
  def release(stop_id) when is_binary(stop_id) do
    case Registry.lookup(@registry, stop_id) do
      [{pid, _value}] ->
        _outcome = DynamicSupervisor.terminate_child(@holds, pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Whether any process holds the arrivals key of `stop_id` in the demand
  registry, a vehicle page that has the stop open included. A registry that
  does not answer holds nothing.
  """
  @spec demanded?(String.t()) :: boolean()
  def demanded?(stop_id) when is_binary(stop_id) do
    Demand.holder_count(Demand, DemandKey.arrivals(stop_id)) > 0
  catch
    :exit, _reason -> false
  end

  @impl Supervisor
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @holds, strategy: :one_for_one, max_children: @hold_count_max}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
