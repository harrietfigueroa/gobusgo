defmodule Gobusgo.Routing.Snapshots do
  @check_interval_ms 600_000
  @run_deadline_ms 120_000
  @format_version Gobusgo.Routing.SnapshotFormat.version()

  @moduledoc """
  The process that holds the manifest of the published routing snapshots,
  one per service date the schedule view holds.

  A build writes a snapshot's files through `Gobusgo.Writer` and then hands
  its manifest entry here with `record/2`, so the manifest names only files
  already stored. The process also holds, per service date, the SHA-256 of
  the inputs the entry was built from and the UTC date it was built on, so
  a build passes over a date whose inputs are unchanged since a build of
  the same day. A build on a later day writes the files again under that
  day, which keeps every file the manifest names inside its retention.

  A date whose trip path build failed is recorded without its trip paths
  and with the state of `Gobusgo.Routing.TripPathRetry`, which the build
  reads to build only the trip paths again once the backoff has passed.

  The manifest is what this node built: it starts empty on every start, and
  the first build after a start builds every date, trip paths included, so
  a start retries a failed trip path build at once.

  `spec/1` is the spec of the scheduler that checks every
  #{@check_interval_ms} ms whether to build, with #{@run_deadline_ms} ms for
  a run.
  """

  use GenServer

  alias Gobusgo.Assert
  alias Gobusgo.Routing.Snapshots.Build
  alias Gobusgo.Scheduler

  @type server :: GenServer.server()

  @type built :: %{
          inputs_sha256: binary(),
          built_on: Date.t(),
          entry: map(),
          trip_path_failure: :none | Gobusgo.Routing.TripPathRetry.state()
        }

  @doc "Starts the process. `:name` registers it."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name])
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  The manifest: the format version and the entry of every snapshot, in
  service date order.
  """
  @spec manifest(server()) :: %{String.t() => term()}
  def manifest(server) do
    entries = GenServer.call(server, :entries)

    %{
      "formatVersion" => @format_version,
      "snapshots" =>
        entries
        |> Enum.sort_by(fn {date, _entry} -> date end, Date)
        |> Enum.map(&elem(&1, 1).entry)
    }
  end

  @doc """
  What each service date's current snapshot was built from and on, its
  entry, and the state of its failed trip path builds, `:none` where the
  last one succeeded or none was made.
  """
  @spec built(server()) :: %{Date.t() => built()}
  def built(server) do
    server
    |> GenServer.call(:entries)
    |> Map.new(fn {date, entry} ->
      {date, Map.take(entry, [:inputs_sha256, :built_on, :entry, :trip_path_failure])}
    end)
  end

  @doc """
  Makes `snapshot.entry` the manifest entry of `snapshot.service_date`,
  built on `snapshot.built_on` from inputs whose SHA-256 is
  `snapshot.inputs_sha256`, with `snapshot.trip_path_failure`, the state of
  its failed trip path builds or `:none`. A later `record/2` of the date
  replaces all of it, so the failure state ends with the inputs it is of.
  """
  @spec record(server(), %{
          service_date: Date.t(),
          entry: map(),
          inputs_sha256: binary(),
          built_on: Date.t(),
          trip_path_failure: :none | Gobusgo.Routing.TripPathRetry.state()
        }) :: :ok
  def record(
        server,
        %{
          service_date: %Date{},
          entry: entry,
          inputs_sha256: sha256,
          built_on: %Date{},
          trip_path_failure: failure
        } = snapshot
      )
      when is_map(entry) and byte_size(sha256) == 32 and (failure == :none or is_map(failure)) do
    GenServer.call(server, {:record, snapshot})
  end

  @doc "Drops the entry of every service date outside `service_dates`."
  @spec retain(server(), [Date.t()]) :: :ok
  def retain(server, service_dates) when is_list(service_dates) do
    GenServer.call(server, {:retain, service_dates})
  end

  @doc """
  The spec of the scheduler that builds the snapshots of `options[:server]`.
  The other options go to `Gobusgo.Routing.Snapshots.Build.run/1`. The spec
  passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(Keyword.t()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: Gobusgo.Routing.SnapshotScheduler,
      run: fn -> Build.run(options) end,
      cadence: %{policy: {:fixed, @check_interval_ms}, signals: &no_signals/0},
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call(:entries, _from, entries), do: {:reply, entries, entries}

  def handle_call({:record, %{service_date: date} = snapshot}, _from, entries) do
    {:reply, :ok, Map.put(entries, date, Map.delete(snapshot, :service_date))}
  end

  def handle_call({:retain, service_dates}, _from, entries) do
    {:reply, :ok, Map.take(entries, service_dates)}
  end
end
