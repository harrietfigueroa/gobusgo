defmodule GobusgoWeb.Mcp.StopHolds.Hold do
  @moduledoc """
  One hold of `GobusgoWeb.Mcp.StopHolds`: a process that holds the arrivals
  key of one stop in `Gobusgo.Demand` until its time is up or it is
  stopped. The key is the process's, so the registry frees it when the
  process exits however it exits.

  Starting a hold the demand registry refuses returns `:ignore`. A hold is
  never restarted, since a restart would hold a stop nobody asked for again.
  """

  use GenServer, restart: :temporary

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey

  @call_timeout_ms 5_000

  @spec start_link(%{stop_id: String.t(), hold_ms: pos_integer(), registry: atom()}) ::
          GenServer.on_start()
  def start_link(%{stop_id: stop_id, hold_ms: hold_ms, registry: registry} = arguments)
      when is_binary(stop_id) and is_integer(hold_ms) and hold_ms > 0 do
    GenServer.start_link(__MODULE__, arguments, name: {:via, Registry, {registry, stop_id}})
  end

  @doc "Replaces the time left of the hold `pid` with `hold_ms` milliseconds from now."
  @spec renew(pid(), pos_integer()) :: :ok
  def renew(pid, hold_ms) when is_pid(pid) and is_integer(hold_ms) and hold_ms > 0 do
    GenServer.call(pid, {:renew, hold_ms}, @call_timeout_ms)
  catch
    # A hold that ended between the lookup and the call has nothing to renew.
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(%{stop_id: stop_id, hold_ms: hold_ms}) do
    # Trapping exits runs `terminate/2` when the supervisor stops the hold,
    # so the key is released before `release/1` returns.
    Process.flag(:trap_exit, true)

    case Demand.register(Demand, DemandKey.arrivals(stop_id)) do
      :ok ->
        {:ok, %{stop_id: stop_id, timer: Process.send_after(self(), :expire, hold_ms)}}

      {:error, _bound_exceeded} ->
        :ignore
    end
  end

  @impl GenServer
  def handle_call({:renew, hold_ms}, _from, %{timer: timer} = hold) do
    _remaining_ms = Process.cancel_timer(timer)
    {:reply, :ok, %{hold | timer: Process.send_after(self(), :expire, hold_ms)}}
  end

  @impl GenServer
  def handle_info(:expire, hold), do: {:stop, :normal, hold}

  @impl GenServer
  def terminate(_reason, %{stop_id: stop_id}) do
    Demand.release(Demand, DemandKey.arrivals(stop_id))
    :ok
  catch
    # A registry that is down holds no key to release.
    :exit, _reason -> :ok
  end
end
