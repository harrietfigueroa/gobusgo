defmodule Gobusgo.Test.CorePages.Scenarios do
  @moduledoc """
  The scenarios of the core page check and the runs that compare them: what
  a rider does on the vehicle page or in an MCP App, the regions read once
  the page shows it, and the comparison of those reads between the build on
  each core of `Gobusgo.Test.CorePages.Builds`.

  `prepare/1` is the setup of a module of the check: it seeds the network,
  builds both cores, keeps a copy of the bundles and the worker the server
  served, and puts that copy back when the module ends.
  """

  import ExUnit.Assertions
  import PhoenixTest, only: [assert_has: 3, click_button: 2, fill_in: 3, select: 3, visit: 2]
  import PhoenixTest.Playwright, only: [click: 2, click: 3, reload_page: 2, type: 3]

  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.Test.CorePages
  alias Gobusgo.Test.CorePages.Builds
  alias Gobusgo.Test.CorePages.Network
  alias Gobusgo.Test.CorePages.Server
  alias GobusgoWeb.Mcp.ArrivalsBoardDocument
  alias GobusgoWeb.Mcp.Tools.ArrivalsBoard

  @work_dir Path.expand("../../../tmp/core_pages", __DIR__)
  @trace_dir Path.join(@work_dir, "traces")
  @load_timeout_ms 30_000
  @offline_timeout_ms 60_000
  @board_stop_id "1_1003"
  @minute_ms 60_000
  # A page of the test server's origin that renders no application script,
  # into which a scenario writes its MCP host.
  @host_path "/core-pages-host"

  @typedoc "A scenario: its name, the instant its clock reads, the favorites it stores, and its run."
  @type t :: %{
          name: String.t(),
          pinned_at: DateTime.t(),
          favorites: [map()],
          run: (PhoenixTest.Playwright.t() -> %{String.t() => term()})
        }

  @doc """
  Seeds the network, builds both cores under `tmp/core_pages/<builds>`
  with `extra_aliases` added, and keeps a copy of what the server served
  until the calling module ends. Returns the context the runs read.
  """
  @spec prepare(%{builds: String.t(), extra_aliases: map()}) :: %{builds_dir: String.t()}
  def prepare(%{builds: builds, extra_aliases: extra_aliases}) do
    base_dir = Path.join(@work_dir, "data")
    original_dir = Path.join(@work_dir, "original")
    :ok = Builds.preserve(original_dir)
    File.rm_rf!(base_dir)
    restore = Network.configure(base_dir)

    ExUnit.Callbacks.on_exit(fn ->
      :ok = Builds.restore(original_dir)
      restore.()
    end)

    :ok = Network.seed(base_dir, DateTime.utc_now())
    builds_dir = Builds.build(Path.join(@work_dir, builds), extra_aliases)
    %{builds_dir: builds_dir}
  end

  @doc "The scenario `name`, with its clock pinned at `pinned_at`."
  @spec scenario(atom(), DateTime.t()) :: t()
  def scenario(:trip_depart_at, pinned_at) do
    %{
      name: "trip plan, depart at",
      pinned_at: pinned_at,
      favorites: [],
      run:
        &plan_trip(&1, %{mode: "Depart at", clock: "08:10", window: "Leaving at 8:10 am tomorrow"})
    }
  end

  def scenario(:trip_arrive_by, pinned_at) do
    %{
      name: "trip plan, arrive by",
      pinned_at: pinned_at,
      favorites: [],
      run:
        &plan_trip(&1, %{
          mode: "Arrive by",
          clock: "08:45",
          window: "Arriving by 8:45 am tomorrow"
        })
    }
  end

  def scenario(:board_for_time, pinned_at) do
    tool_input = %{
      "stopId" => @board_stop_id,
      "when" => %{"mode" => "departAt", "day" => "tomorrow", "time" => "08:00"}
    }

    {:ok, tool_result} = ArrivalsBoard.call(tool_input)

    %{
      name: "arrivals board for a time",
      pinned_at: pinned_at,
      favorites: [],
      run:
        &show_board(&1, %{
          tool_input: tool_input,
          tool_result: tool_result,
          host_capabilities: %{"updateModelContext" => %{}},
          regions: [{:app, "board", "#mcp-arrivals-board"}, {:model_context, "model context"}]
        })
    }
  end

  # The live board counts its rows down from the device's clock, and the
  # server keeps an arrival only until it passes, so the arrivals are
  # fetched at the instant the clock is pinned to.
  def scenario(:mcp_board, pinned_at) do
    :ok = seed_arrivals(pinned_at)
    tool_input = %{"stopId" => @board_stop_id}
    {:ok, tool_result} = ArrivalsBoard.call(tool_input)

    %{
      name: "MCP arrivals board",
      pinned_at: pinned_at,
      favorites: [],
      run:
        &show_board(&1, %{
          tool_input: tool_input,
          tool_result: tool_result,
          host_capabilities: %{},
          regions: [{:app, "board", "#mcp-arrivals-board"}]
        })
    }
  end

  def scenario(:offline, pinned_at) do
    %{
      name: "offline markers and arrivals",
      pinned_at: pinned_at,
      favorites: [%{"stopId" => @board_stop_id, "name" => Network.stop_name(@board_stop_id)}],
      run: &start_offline/1
    }
  end

  @doc """
  Runs `scenario` once on each core's build, in the order of
  `Builds.cores/0`, and returns each run as `{core, conn, regions}`. A run
  that raises fails with the browser, the scenario, and the core, and
  keeps the traces of the runs so far.
  """
  @spec runs(map(), t()) :: [{Builds.core(), PhoenixTest.Playwright.t(), map()}]
  def runs(context, scenario) do
    runs = Enum.reduce(Builds.cores(), [], &[run(context, scenario, &1, &2) | &2])
    Enum.reverse(runs)
  end

  @doc """
  Runs `scenario` on both cores and fails on any region whose reads differ,
  naming the browser, the scenario, and the region and keeping both runs'
  traces.
  """
  @spec compare(map(), t()) :: :ok
  def compare(context, scenario) do
    [{_reference_core, _reference_conn, reference} | others] = runs = runs(context, scenario)

    # Two cores that both show nothing agree, so the first core's reads must
    # show the scenario before the others are compared with them.
    assert CorePages.empty_regions(reference) == [],
           "#{context.browser_pool} · #{scenario.name}: regions the JavaScript core left empty"

    for {core, _conn, regions} <- others do
      case CorePages.differences(reference, regions) do
        [] ->
          :ok

        differences ->
          sessions =
            for {run_core, conn, _regions} <- runs, do: {label(context, scenario, run_core), conn}

          traces = CorePages.keep_traces(sessions, @trace_dir)

          flunk(
            difference_message(%{
              context: context,
              scenario: scenario,
              core: core,
              differences: differences,
              reference: reference,
              regions: regions,
              traces: traces
            })
          )
      end
    end

    :ok
  end

  defp run(context, scenario, core, earlier) do
    Builds.install(context.builds_dir, core)
    conn = CorePages.open_session(context, scenario)

    try do
      {core, conn, scenario.run.(conn)}
    rescue
      error ->
        sessions =
          for {run_core, run_conn, _regions} <- [{core, conn, nil} | earlier],
              do: {label(context, scenario, run_core), run_conn}

        traces = CorePages.keep_traces(sessions, @trace_dir)

        message =
          "#{context.browser_pool} · #{scenario.name} · #{core}: #{Exception.message(error)}" <>
            "\nTraces:\n" <> Enum.join(traces, "\n")

        reraise ExUnit.AssertionError, [message: message], __STACKTRACE__
    end
  end

  defp label(context, scenario, core), do: "#{context.browser_pool}-#{scenario.name}-#{core}"

  defp difference_message(failure) do
    lines =
      for name <- failure.differences do
        """
        #{failure.context.browser_pool} · #{failure.scenario.name} · #{name}
          javascript: #{inspect(Map.get(failure.reference, name), pretty: true, limit: :infinity)}
          #{failure.core}: #{inspect(Map.get(failure.regions, name), pretty: true, limit: :infinity)}
        """
      end

    Enum.join(lines, "\n") <> "\nTraces:\n" <> Enum.join(failure.traces, "\n")
  end

  defp plan_trip(conn, %{mode: mode, clock: clock, window: window}) do
    conn
    |> visit("/vehicles")
    |> assert_has("#trip-search-input", timeout: @load_timeout_ms)
    |> click("#trip-from")
    |> type("#trip-search-input", "Yesler")
    |> click("[role=option]", Network.stop_name("1_1001"))
    |> click("#trip-search-input")
    |> type("#trip-search-input", "Broadway")
    |> click("[role=option]", Network.stop_name("1_2005"))
    |> click_button(mode)
    |> select("Day", option: "Tomorrow")
    |> fill_in("Time", with: clock)
    |> assert_has(".trip-window", text: window, timeout: @load_timeout_ms)
    |> CorePages.await_page(source_drawn("trip-journey"), @load_timeout_ms)
    |> CorePages.settled_regions([
      {:page, "trip planner", "#trip-planner"},
      {:page, "trip strip", "#trip-strip"},
      {:map_sources, "map sources"}
    ])
  end

  defp show_board(conn, board) do
    {:ok, base_url} = Application.fetch_env(:phoenix_test, :base_url)

    resource =
      ArrivalsBoardDocument.render(%{
        origin: base_url,
        script_path: "/assets/js/arrivals_board.js",
        stylesheet_path: "/assets/css/app.css"
      })

    conn
    |> visit(@host_path)
    |> CorePages.render_app(%{
      resource: resource,
      tool_input: board.tool_input,
      tool_result: board.tool_result,
      host_capabilities: board.host_capabilities
    })
    |> assert_has(CorePages.in_app(".arrival-rows li"), timeout: @load_timeout_ms)
    |> CorePages.settled_regions(board.regions)
  end

  # Loads the page online until its worker controls it, the worker keeps a
  # copy of the page, and the offline schedules are saved; then stops the
  # server and loads the page again, which starts from the worker's copy and
  # places the scheduled vehicles and the favorite stop's arrivals itself.
  defp start_offline(conn) do
    conn
    |> visit("/vehicles")
    |> CorePages.await_page(
      "async () => (await navigator.serviceWorker.ready).active !== null",
      @offline_timeout_ms
    )
    |> reload_page(timeout: @load_timeout_ms)
    |> CorePages.await_page(offline_saved(), @offline_timeout_ms)

    try do
      :ok = Server.stop()

      conn
      |> reload_page(timeout: @load_timeout_ms)
      |> CorePages.await_page(source_drawn("vehicle-markers"), @offline_timeout_ms)
      |> click("#panel-tab-favorites")
      |> assert_has("#favorite-stop .arrival-rows li", timeout: @offline_timeout_ms)
      |> CorePages.settled_regions([
        {:page, "favorites", "#favorite-stop"},
        {:map_sources, "map sources"}
      ])
    after
      :ok = Server.start()
    end
  end

  # The page the worker controls has ended a save of the offline schedules,
  # whose last write is the saved index, so no save is under way when the
  # server stops.
  defp offline_saved do
    "() => navigator.serviceWorker.controller !== null && window.__corePagesIndexSaves > 0"
  end

  # The map's GeoJSON source `source_id` holds a feature. The map has no
  # style for a moment after it is made, and WebKit's wait ends at a
  # throw, so a map that cannot answer yet answers false.
  defp source_drawn(source_id) do
    """
    () => {
      try {
        const source = window.__corePagesMap.getStyle().sources[#{JSON.encode!(source_id)}]
        return source.data.features.length > 0
      } catch (error) {
        return false
      }
    }
    """
  end

  # The arrivals of route 10 at the board's stop the next half hour, the
  # first two predicted a minute late, fetched at `fetched_at`.
  defp seed_arrivals(fetched_at) do
    fetched_ms = DateTime.to_unix(fetched_at, :millisecond)
    service_date = DateTime.to_date(fetched_at)

    arrivals =
      for {minutes, index} <- Enum.with_index([3, 9, 13, 19, 23, 29]) do
        scheduled_ms = fetched_ms + minutes * @minute_ms
        arrival(%{index: index, scheduled_ms: scheduled_ms, service_date_ms: fetched_ms})
      end

    record =
      ArrivalBatch.Records.build(%{
        stop_id: @board_stop_id,
        destination:
          "raw/oba/arrivals-and-departures-for-stop/dt=#{service_date}/stop=#{@board_stop_id}/file.json.gz",
        fetched_at: fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: Gobusgo.RequestId.generate(),
        arrivals: arrivals
      })

    FetchView.apply_records(Gobusgo.OneBusAway.ArrivalView, [record.value])
  end

  defp arrival(%{index: index, scheduled_ms: scheduled_ms, service_date_ms: service_date_ms}) do
    predicted = index < 2

    predicted_ms =
      case predicted do
        true -> scheduled_ms + @minute_ms
        false -> nil
      end

    %{
      trip_id: "1_10_0_#{index}",
      service_date_ms: service_date_ms,
      stop_sequence: 2,
      route_id: "1_10",
      route_short_name: "10",
      route_long_name: nil,
      trip_headsign: "Belltown",
      arrival_enabled: true,
      departure_enabled: true,
      scheduled_arrival_time_ms: scheduled_ms,
      scheduled_departure_time_ms: scheduled_ms,
      predicted: predicted,
      predicted_arrival_time_ms: predicted_ms,
      predicted_departure_time_ms: predicted_ms,
      vehicle_id: nil,
      vehicle_schedule_deviation_seconds: nil
    }
  end
end
