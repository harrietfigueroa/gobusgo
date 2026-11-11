defmodule Gobusgo.Addresses do
  @prefix "addresses"
  @manifest_name_prefix "manifest-"
  @check_interval_ms 3_600_000
  @run_deadline_ms 3_300_000
  @slot_hour_utc 10
  @reader_keep_seconds 31_536_000
  @discovery_page_count_max 20
  @inputs_sha256_bytes 32

  @moduledoc """
  The process that holds the manifest of the published address shards, and
  the schedule of the build that makes them. Read
  `lib/gobusgo/addresses/AGENTS.md` before changing the address build.

  A build stores its files through `Gobusgo.Writer` at
  `#{@prefix}/dt=<date>/`, the manifest last, at
  `#{@prefix}/dt=<date>/#{@manifest_name_prefix}<time>-<sha256>.json`, the UTC time of
  the build and the SHA-256 of the input it was built from, and then hands
  the manifest here with `record/2`, so the manifest names only files
  already stored. After a start the process finds the newest stored
  manifest with `Gobusgo.Reader.discover/2`, so a start downloads and builds
  nothing where a build is stored.

  The process holds the SHA-256 of the input of the current build and the
  UTC date it was built on, so a build passes over input that is unchanged
  since a build of the same day. A build on a later day writes the files
  again under that day, which keeps every file the manifest names inside
  its retention.

  `spec/1` is the spec of the scheduler that checks every
  #{@check_interval_ms} ms whether a build is due, with #{@run_deadline_ms}
  ms for a run. A build is due when there is no build, or when the current
  build is from an earlier UTC date and the time is past #{@slot_hour_utc}:00
  UTC.

  ## Logs

  `Address manifest discovery failed` at `warning`, with the `reason`, when
  the newest stored manifest cannot be found or read after a start; the
  process then holds none until its first build.
  """

  use GenServer

  require Logger

  alias Gobusgo.Addresses.Build
  alias Gobusgo.Assert
  alias Gobusgo.Reader
  alias Gobusgo.Scheduler
  alias Gobusgo.Schema

  @type server :: GenServer.server()

  @type built :: %{inputs_sha256: binary(), built_at: DateTime.t(), built_on: Date.t()}

  @manifest_schema {:map,
                    %{
                      "builtAt" => :string,
                      "inputsSha256" => :string,
                      "index" => {:map, %{"path" => :string}},
                      "shards" => {:list, {:map, %{"path" => :string}}}
                    }}

  @doc "The prefix of every stored file's destination, without a trailing `/`."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  How long a reader may keep a stored file, a year: each file's name holds
  the SHA-256 of its content, so the content at a destination never changes.
  """
  @spec reader_keep_seconds() :: pos_integer()
  def reader_keep_seconds, do: @reader_keep_seconds

  @doc """
  The destination of the manifest of a build made at `manifest.built_at`
  from the input whose SHA-256 is `manifest.inputs_sha256`, in the
  directory `manifest.directory`. The name holds both, the time first, so
  manifests sort in the order of their builds.
  """
  @spec manifest_destination(%{
          directory: String.t(),
          built_at: DateTime.t(),
          inputs_sha256: binary()
        }) :: String.t()
  def manifest_destination(%{
        directory: directory,
        built_at: %DateTime{} = built_at,
        inputs_sha256: inputs_sha256
      })
      when byte_size(inputs_sha256) == @inputs_sha256_bytes do
    built_at = DateTime.shift_zone!(built_at, "Etc/UTC")
    time = Calendar.strftime(built_at, "%Y%m%dT%H%M%S%fZ")
    sha256 = Base.encode16(inputs_sha256, case: :lower)
    destination = "#{directory}/#{@manifest_name_prefix}#{time}-#{sha256}.json"
    Assert.condition(String.starts_with?(destination, @prefix <> "/"), "under the prefix")
    destination
  end

  @doc "Whether `destination` names a manifest."
  @spec manifest_destination?(String.t()) :: boolean()
  def manifest_destination?(destination) when is_binary(destination) do
    String.starts_with?(Path.basename(destination), @manifest_name_prefix)
  end

  @doc """
  Whether a build is due at `check.now`: with no build, or when the current
  build is from an earlier UTC date and the UTC hour has reached the slot.
  """
  @spec due?(%{built: {:ok, built()} | :none, now: DateTime.t()}) :: boolean()
  def due?(%{built: :none, now: %DateTime{}}), do: true

  def due?(%{built: {:ok, %{built_on: built_on}}, now: %DateTime{} = now}) do
    today = DateTime.to_date(now)
    is_later_day = Date.after?(today, built_on)
    is_in_slot = now.hour >= @slot_hour_utc
    is_later_day and is_in_slot
  end

  @doc """
  Starts the process. `:name` registers it; `:read_options` go to
  `Gobusgo.Reader.discover/2` and `Gobusgo.Reader.read/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, read_options: []])
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    GenServer.start_link(__MODULE__, Keyword.fetch!(options, :read_options), name: name)
  end

  @doc "The manifest of the current build as the JSON object clients read, or `:none`."
  @spec manifest(server()) :: {:ok, %{String.t() => term()}} | :none
  def manifest(server), do: GenServer.call(server, :manifest)

  @doc "The SHA-256 of the input of the current build and when it was built, or `:none`."
  @spec built(server()) :: {:ok, built()} | :none
  def built(server), do: GenServer.call(server, :built)

  @doc """
  Makes `build.manifest` the manifest of the current build, made at
  `build.built_at` from the input whose SHA-256 is `build.inputs_sha256`.
  """
  @spec record(server(), %{
          manifest: %{String.t() => term()},
          inputs_sha256: binary(),
          built_at: DateTime.t()
        }) :: :ok
  def record(
        server,
        %{manifest: manifest, inputs_sha256: inputs_sha256, built_at: %DateTime{}} = build
      )
      when is_map(manifest) and byte_size(inputs_sha256) == @inputs_sha256_bytes do
    GenServer.call(server, {:record, build})
  end

  @doc """
  One check of the scheduler: runs `Gobusgo.Addresses.Build.run/1` with
  `options` when a build is due at the time `options[:clock]` gives, and
  does nothing otherwise.
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(options) when is_list(options) do
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    built = built(Keyword.fetch!(options, :server))

    if due?(%{built: built, now: clock.()}) do
      Build.run(options)
    else
      {:ok, %{outcome: :not_due}}
    end
  end

  @doc """
  The spec of the scheduler that builds the shards of `options[:server]`.
  The other options go to `Gobusgo.Addresses.Build.run/1`. The spec passes
  `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(keyword()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: Gobusgo.AddressScheduler,
      run: fn -> check(options) end,
      cadence: %{policy: {:fixed, @check_interval_ms}, signals: &no_signals/0},
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  @impl GenServer
  def init(read_options) do
    {:ok, %{manifest: nil, built: nil}, {:continue, {:discover, read_options}}}
  end

  @impl GenServer
  def handle_continue({:discover, read_options}, state) do
    case discover_manifest(read_options) do
      {:ok, %{manifest: manifest, built: built}} ->
        {:noreply, %{state | manifest: manifest, built: built}}

      :none ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Address manifest discovery failed", reason: inspect(reason))
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:manifest, _from, %{manifest: nil} = state), do: {:reply, :none, state}
  def handle_call(:manifest, _from, state), do: {:reply, {:ok, state.manifest}, state}
  def handle_call(:built, _from, %{built: nil} = state), do: {:reply, :none, state}
  def handle_call(:built, _from, state), do: {:reply, {:ok, state.built}, state}

  def handle_call({:record, build}, _from, state) do
    built = %{
      inputs_sha256: build.inputs_sha256,
      built_at: build.built_at,
      built_on: DateTime.to_date(build.built_at)
    }

    {:reply, :ok, %{state | manifest: build.manifest, built: built}}
  end

  # The manifests sort after the shard files of their day and after every
  # earlier day, so the first manifest of a newest-first listing is the
  # newest build's; the listing is paged until one is found.
  defp discover_manifest(read_options) do
    case find_manifest(%{
           cursor: nil,
           pages_left: @discovery_page_count_max,
           options: read_options
         }) do
      {:ok, destination} -> read_manifest(destination, read_options)
      :none -> :none
      {:error, _reason} = failure -> failure
    end
  end

  defp find_manifest(%{pages_left: 0}), do: :none

  defp find_manifest(%{cursor: cursor, pages_left: pages_left, options: options} = state) do
    request = %{
      prefix: @prefix <> "/",
      limit: Reader.discovery_limit_max(),
      order: :descending,
      cursor: cursor
    }

    case Reader.discover(request, options) do
      {:ok, %{destinations: destinations, cursor: next_cursor}} ->
        case Enum.find(destinations, &manifest_destination?/1) do
          nil when is_nil(next_cursor) -> :none
          nil -> find_manifest(%{state | cursor: next_cursor, pages_left: pages_left - 1})
          destination -> {:ok, destination}
        end

      {:error, _reason} = failure ->
        failure
    end
  end

  defp read_manifest(destination, read_options) do
    with {:ok, content} <- Reader.read(destination, read_options),
         {:ok, manifest} <- decode(content),
         {:ok, built_at, 0} <- DateTime.from_iso8601(manifest["builtAt"]),
         {:ok, inputs_sha256} <- Base.decode16(manifest["inputsSha256"], case: :lower),
         true <- byte_size(inputs_sha256) == @inputs_sha256_bytes do
      {:ok,
       %{
         manifest: manifest,
         built: %{
           inputs_sha256: inputs_sha256,
           built_at: built_at,
           built_on: DateTime.to_date(built_at)
         }
       }}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :malformed_manifest}
    end
  end

  defp decode(content) do
    with {:ok, decoded} <- JSON.decode(content),
         nil <- Schema.mismatch(decoded, @manifest_schema) do
      {:ok, decoded}
    else
      _malformed -> {:error, :malformed_manifest}
    end
  end
end
