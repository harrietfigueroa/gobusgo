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
  The process that holds the manifest of each county's published address
  shards, and the schedule of the builds that make them, one county at a
  time. Read `lib/gobusgo/addresses/AGENTS.md` before changing the address
  build.

  A county's build stores its files through `Gobusgo.Writer` at
  `#{@prefix}/dt=<date>/`, its manifest last, at
  `#{@prefix}/dt=<date>/#{@manifest_name_prefix}<county>-<time>-<sha256>.json`,
  the UTC time of the build and the SHA-256 of the input it was built from,
  and then hands the manifest here with `record/2`, so a manifest names only
  files already stored. A manifest named `#{@manifest_name_prefix}<time>-<sha256>.json`,
  as builds were named before they were made per county, is King County's.
  After a start the process finds the newest stored manifest of each county
  with `Gobusgo.Reader.discover/2`, so a start downloads and builds nothing
  for a county whose build is stored.

  `manifest/1` answers every county's manifest together, in the order of
  their names, so a county that fails leaves the others' builds current.
  The process holds each county's SHA-256 of its input and the UTC date it
  was built on, so a county's build passes over input that is unchanged
  since its build of the same day. A build on a later day writes the files
  again under that day, which keeps every file a manifest names inside its
  retention.

  `spec/1` is the spec of the scheduler that checks every
  #{@check_interval_ms} ms whether a county's build is due and builds the
  first that is, in the order of the sources, with #{@run_deadline_ms} ms
  for a run, under which each county's own deadline sits. One check builds
  at most one county, and the scheduler runs one check at a time, so the
  counties are built one after another. A county is due when it has no
  build, or when its build is from an earlier UTC date and the time is past
  #{@slot_hour_utc}:00 UTC.

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

  @legacy_county "king"

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
  The destination of the manifest of `manifest.county`'s build made at
  `manifest.built_at` from the input whose SHA-256 is
  `manifest.inputs_sha256`, in the directory `manifest.directory`. The name
  holds the county, then the time, then the hash, so a county's manifests
  sort in the order of its builds.
  """
  @spec manifest_destination(%{
          directory: String.t(),
          county: atom(),
          built_at: DateTime.t(),
          inputs_sha256: binary()
        }) :: String.t()
  def manifest_destination(%{
        directory: directory,
        county: county,
        built_at: %DateTime{} = built_at,
        inputs_sha256: inputs_sha256
      })
      when is_atom(county) and byte_size(inputs_sha256) == @inputs_sha256_bytes do
    county_name = Atom.to_string(county)
    Assert.condition(county_name =~ ~r/^[a-z_]+$/, "a county name is lower case letters")
    built_at = DateTime.shift_zone!(built_at, "Etc/UTC")
    time = Calendar.strftime(built_at, "%Y%m%dT%H%M%S%fZ")
    sha256 = Base.encode16(inputs_sha256, case: :lower)
    destination = "#{directory}/#{@manifest_name_prefix}#{county_name}-#{time}-#{sha256}.json"
    Assert.condition(String.starts_with?(destination, @prefix <> "/"), "under the prefix")
    destination
  end

  @doc """
  The county whose manifest `destination` names, or `:none` for a file that
  is no manifest. A manifest whose name begins with its time is King
  County's.
  """
  @spec manifest_county(String.t()) :: {:ok, String.t()} | :none
  def manifest_county(destination) when is_binary(destination) do
    case Path.basename(destination) do
      @manifest_name_prefix <> rest -> {:ok, county_of(rest)}
      _other -> :none
    end
  end

  defp county_of(<<digit, _rest::binary>>) when digit in ?0..?9, do: @legacy_county

  defp county_of(rest) do
    [county | _time] = String.split(rest, "-", parts: 2)
    county
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

  @doc """
  Every county's current manifest as the JSON object clients read,
  `{"counties": [...]}`, each entry a county's manifest with its `county`,
  in the order of the counties' names; or `:none` while no county is built.
  """
  @spec manifest(server()) :: {:ok, %{String.t() => term()}} | :none
  def manifest(server), do: GenServer.call(server, :manifest)

  @doc "The SHA-256 of the input of `county`'s current build and when it was built, or `:none`."
  @spec built(server(), atom()) :: {:ok, built()} | :none
  def built(server, county) when is_atom(county),
    do: GenServer.call(server, {:built, Atom.to_string(county)})

  @doc """
  Makes `build.manifest` the manifest of `build.county`'s current build,
  made at `build.built_at` from the input whose SHA-256 is
  `build.inputs_sha256`. The other counties' builds stay as they are.
  """
  @spec record(server(), %{
          county: atom(),
          manifest: %{String.t() => term()},
          inputs_sha256: binary(),
          built_at: DateTime.t()
        }) :: :ok
  def record(
        server,
        %{county: county, manifest: manifest, inputs_sha256: inputs_sha256, built_at: %DateTime{}} =
          build
      )
      when is_atom(county) and is_map(manifest) and
             byte_size(inputs_sha256) == @inputs_sha256_bytes do
    GenServer.call(server, {:record, build})
  end

  @doc """
  One check of the scheduler: runs `Gobusgo.Addresses.Build.run/1` for the
  first county of `options[:sources]` (by default
  `Gobusgo.Addresses.Build.sources/0`) whose build is due at the time
  `options[:clock]` gives, with that county's options, and does nothing
  when none is. Its outcome names the county it built.
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(options) when is_list(options) do
    {sources, options} = Keyword.pop(options, :sources, Build.sources())
    now = Keyword.get(options, :clock, &DateTime.utc_now/0).()
    server = Keyword.fetch!(options, :server)
    is_due = fn {source, _options} -> due?(%{built: built(server, source.name()), now: now}) end

    case Enum.find(sources, is_due) do
      {source, source_options} ->
        build_county(%{source: source, source_options: source_options, options: options})

      nil ->
        {:ok, %{outcome: :not_due}}
    end
  end

  defp build_county(%{source: source, source_options: source_options, options: options}) do
    run_options = Keyword.merge(options, source: source, source_options: source_options)

    case Build.run(run_options) do
      {:ok, outcome} -> {:ok, Map.put(outcome, :county, source.name())}
      {:error, _reason} = failure -> failure
    end
  end

  @doc """
  The spec of the scheduler that builds the shards of `options[:server]`.
  The other options go to `Gobusgo.Addresses.Build.run/1`. The spec passes
  `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(keyword()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    for {source, _options} <- Build.sources() do
      Assert.condition(
        source.run_deadline_ms() < @run_deadline_ms,
        "#{source.name()}'s deadline is under the scheduler's #{@run_deadline_ms} ms"
      )
    end

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
    {:ok, %{counties: %{}}, {:continue, {:discover, read_options}}}
  end

  @impl GenServer
  def handle_continue({:discover, read_options}, state) do
    case discover_manifests(read_options) do
      {:ok, counties} ->
        {:noreply, %{state | counties: counties}}

      {:error, reason} ->
        Logger.warning("Address manifest discovery failed", reason: inspect(reason))
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:manifest, _from, %{counties: counties} = state) when counties == %{},
    do: {:reply, :none, state}

  def handle_call(:manifest, _from, %{counties: counties} = state) do
    manifests =
      counties
      |> Enum.sort_by(fn {county, _held} -> county end)
      |> Enum.map(fn {_county, held} -> held.manifest end)

    {:reply, {:ok, %{"counties" => manifests}}, state}
  end

  def handle_call({:built, county}, _from, %{counties: counties} = state) do
    case Map.fetch(counties, county) do
      {:ok, held} -> {:reply, {:ok, held.built}, state}
      :error -> {:reply, :none, state}
    end
  end

  def handle_call({:record, build}, _from, %{counties: counties} = state) do
    county = Atom.to_string(build.county)

    held = %{
      manifest: Map.put(build.manifest, "county", county),
      built: %{
        inputs_sha256: build.inputs_sha256,
        built_at: build.built_at,
        built_on: DateTime.to_date(build.built_at)
      }
    }

    {:reply, :ok, %{state | counties: Map.put(counties, county, held)}}
  end

  # Manifests sort after the shard files of their day and after every
  # earlier day, and a county's after its earlier ones, so the first
  # manifest of each county in a newest-first listing is its newest build's.
  # The listing is paged to its end or to the page bound, keeping the first
  # manifest of each county it meets.
  defp discover_manifests(read_options) do
    case find_manifests(%{
           cursor: nil,
           pages_left: @discovery_page_count_max,
           options: read_options,
           found: %{}
         }) do
      {:ok, found} -> read_manifests(found, read_options)
      {:error, _reason} = failure -> failure
    end
  end

  defp find_manifests(%{pages_left: 0, found: found}), do: {:ok, found}

  defp find_manifests(%{cursor: cursor, pages_left: pages_left, options: options} = state) do
    request = %{
      prefix: @prefix <> "/",
      limit: Reader.discovery_limit_max(),
      order: :descending,
      cursor: cursor
    }

    case Reader.discover(request, options) do
      {:ok, %{destinations: destinations, cursor: next_cursor}} ->
        found = Enum.reduce(destinations, state.found, &keep_first_manifest/2)

        case next_cursor do
          nil ->
            {:ok, found}

          _more ->
            find_manifests(%{
              state
              | cursor: next_cursor,
                pages_left: pages_left - 1,
                found: found
            })
        end

      {:error, _reason} = failure ->
        failure
    end
  end

  defp keep_first_manifest(destination, found) do
    case manifest_county(destination) do
      {:ok, county} -> Map.put_new(found, county, destination)
      :none -> found
    end
  end

  defp read_manifests(found, read_options) do
    Enum.reduce_while(found, {:ok, %{}}, fn {county, destination}, {:ok, counties} ->
      case read_manifest(destination, read_options) do
        {:ok, held} ->
          manifest = Map.put(held.manifest, "county", county)
          {:cont, {:ok, Map.put(counties, county, %{held | manifest: manifest})}}

        {:error, _reason} = failure ->
          {:halt, failure}
      end
    end)
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
