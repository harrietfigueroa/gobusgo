defmodule GobusgoWeb.RouteStopTiles do
  @prefix "tiles/route-stops"
  @name_prefix "route-stops-"
  @extension ".pmtiles"
  @check_interval_ms 600_000
  @run_deadline_ms 120_000
  @content_sha256_bytes 32

  @moduledoc """
  The tile archive of the routes and stops a map page draws, and the process
  that holds the destination of the current one.

  An archive is stored through `Gobusgo.Writer` at
  `#{@prefix}/dt=<date>/#{@name_prefix}<time>#{@extension}`, the UTC date and
  time of its build, so destinations sort in the order of their builds. The
  writer only creates, so each build is a destination of its own and no
  stored name points at the current one: the process holds it, and after a
  start finds the newest stored archive with `Gobusgo.Reader.discover/2`.

  The process also holds the SHA-256 of the features the current archive was
  built from and the time it was built, so a build whose features are those
  of a current archive younger than its renewal age is passed over, however
  recently the data behind them was fetched. Both are what the process of
  this node built, so the first build after a start always runs.

  `spec/1` is the spec of the scheduler that checks every
  #{@check_interval_ms} ms whether to build, with #{@run_deadline_ms} ms for
  a run.

  ## Logs

  `Route stop tiles discovery failed` at `warning`, with the `reason`, when
  the newest stored archive cannot be found after a start; the process then
  holds no destination until its first build.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Reader
  alias Gobusgo.Scheduler
  alias GobusgoWeb.RouteStopTiles.Build

  @type server :: GenServer.server()

  @doc "The prefix of every stored archive's destination, without a trailing `/`."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The destination of an archive built at `built_at`."
  @spec destination(DateTime.t()) :: String.t()
  def destination(%DateTime{} = built_at) do
    built_at = DateTime.shift_zone!(built_at, "Etc/UTC")
    date = built_at |> DateTime.to_date() |> Date.to_iso8601()
    time = Calendar.strftime(built_at, "%Y%m%dT%H%M%S%fZ")
    destination = "#{@prefix}/dt=#{date}/#{@name_prefix}#{time}#{@extension}"
    Assert.condition(String.starts_with?(destination, @prefix <> "/"), "under the prefix")
    destination
  end

  @doc """
  The time the archive at `destination` was built, read from its name as
  `destination/1` writes it, or `:unrecognized` for a name that holds none.
  """
  @spec built_at(String.t()) :: {:ok, DateTime.t()} | :unrecognized
  def built_at(destination) when is_binary(destination) do
    with [_name, date, time, fraction] <- Regex.run(name_pattern(), Path.basename(destination)),
         {:ok, built_at, 0} <- DateTime.from_iso8601(iso8601(date, time, fraction)) do
      {:ok, built_at}
    else
      _unrecognized -> :unrecognized
    end
  end

  # `%f` of `Calendar.strftime/2` writes one to six digits, as many as the
  # time's precision, and one `0` for a precision of none.
  defp name_pattern do
    ~r/\A#{@name_prefix}(\d{8})T(\d{6})(\d{1,6})Z#{Regex.escape(@extension)}\z/
  end

  defp iso8601(date, time, fraction) do
    <<year::binary-4, month::binary-2, day::binary-2>> = date
    <<hour::binary-2, minute::binary-2, second::binary-2>> = time
    "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{fraction}Z"
  end

  @doc """
  How fresh the archive at `destination` is at `now`: `:none` with no
  destination, `{:current, age_seconds}` while its age is under
  `GobusgoWeb.RouteStopTiles.Build.renewal_age_seconds/0`, `{:stale,
  age_seconds}` from that age on, and `:unrecognized` for a name that holds
  no build time. The age is `now` less the build time the name holds, so an
  archive discovered after a start counts as one built on this node does.
  """
  @spec freshness(%{destination: String.t() | nil, now: DateTime.t()}) ::
          :none | :unrecognized | {:current | :stale, integer()}
  def freshness(%{destination: nil, now: %DateTime{}}), do: :none

  def freshness(%{destination: destination, now: %DateTime{} = now})
      when is_binary(destination) do
    case built_at(destination) do
      {:ok, built_at} ->
        age_seconds = DateTime.diff(now, built_at, :second)

        if age_seconds < Build.renewal_age_seconds() do
          {:current, age_seconds}
        else
          {:stale, age_seconds}
        end

      :unrecognized ->
        :unrecognized
    end
  end

  @doc """
  Starts the process. `:name` registers it; `:read_options` go to
  `Gobusgo.Reader.discover/2`.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, read_options: []])
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    GenServer.start_link(__MODULE__, Keyword.fetch!(options, :read_options), name: name)
  end

  @doc "The destination of the current archive, or `nil` while there is none."
  @spec current_destination(server()) :: String.t() | nil
  def current_destination(server), do: GenServer.call(server, :current_destination)

  @doc """
  The SHA-256 of the features the current archive was built from on this
  node and the time it was built, or `nil` while this node has built none.
  """
  @spec built(server()) :: %{content_sha256: binary(), built_at: DateTime.t()} | nil
  def built(server), do: GenServer.call(server, :built)

  @doc """
  Makes the archive at `build.destination`, built at `build.built_at` from
  the features whose SHA-256 is `build.content_sha256`, the current one.
  """
  @spec record(server(), %{
          destination: String.t(),
          content_sha256: binary(),
          built_at: DateTime.t()
        }) :: :ok
  def record(
        server,
        %{destination: destination, content_sha256: content_sha256, built_at: %DateTime{}} = build
      )
      when is_binary(destination) and is_binary(content_sha256) do
    Assert.condition(String.starts_with?(destination, @prefix <> "/"), "an archive destination")

    Assert.condition(
      byte_size(content_sha256) == @content_sha256_bytes,
      "a SHA-256 is #{@content_sha256_bytes} bytes, got: #{byte_size(content_sha256)}"
    )

    GenServer.call(server, {:record, build})
  end

  @doc """
  The spec of the scheduler that builds the archive of `options[:server]`.
  The other options go to `GobusgoWeb.RouteStopTiles.Build.run/1`. The spec
  passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(Keyword.t()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: GobusgoWeb.RouteStopTilesScheduler,
      run: fn -> Build.run(options) end,
      cadence: %{policy: {:fixed, @check_interval_ms}, signals: &no_signals/0},
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  @impl GenServer
  def init(read_options) do
    {:ok, %{destination: nil, built: nil}, {:continue, {:discover, read_options}}}
  end

  @impl GenServer
  def handle_continue({:discover, read_options}, state) do
    request = %{prefix: @prefix <> "/", limit: 1, order: :descending, cursor: nil}

    case Reader.discover(request, read_options) do
      {:ok, %{destinations: [destination]}} ->
        {:noreply, %{state | destination: destination}}

      {:ok, %{destinations: []}} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Route stop tiles discovery failed", reason: inspect(reason))
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:current_destination, _from, state), do: {:reply, state.destination, state}
  def handle_call(:built, _from, state), do: {:reply, state.built, state}

  def handle_call({:record, %{destination: destination} = build}, _from, state) do
    built = Map.take(build, [:content_sha256, :built_at])
    {:reply, :ok, %{state | destination: destination, built: built}}
  end
end
