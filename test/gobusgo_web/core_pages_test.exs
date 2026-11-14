defmodule GobusgoWeb.CorePagesTest do
  # Checks that the WebAssembly core renders the pages a rider sees as the
  # JavaScript core does: each scenario runs in Chromium, Firefox, and
  # WebKit, once on a build of the page's bundles on each core served by
  # the test server, with the browser's clock pinned and the network of
  # Gobusgo.Test.CorePages.Network as the data, and fails on any region
  # whose accessibility snapshot, rendered text, map source data, or model
  # context differs between the two, naming the browser, the scenario, and
  # the region and keeping both sessions' Playwright traces.
  use PhoenixTest.Playwright.Case,
    async: false,
    parameterize: for(browser <- [:chromium, :firefox, :webkit], do: %{browser_pool: browser})

  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.Test.CorePages
  alias Gobusgo.Test.CorePages.Builds
  alias Gobusgo.Test.CorePages.Network
  alias Gobusgo.Test.CorePages.Server
  alias GobusgoWeb.Mcp.ArrivalsBoardDocument
  alias GobusgoWeb.Mcp.Tools.ArrivalsBoard

  @moduletag :core_pages
  @moduletag capture_log: true
  @moduletag timeout: 300_000

  @work_dir Path.expand("../../tmp/core_pages", __DIR__)
  @trace_dir Path.join(@work_dir, "traces")
  @load_timeout_ms 30_000
  @offline_timeout_ms 60_000
  @board_stop_id "1_1003"
  # A page of the test server's origin that renders no application script,
  # into which a scenario writes its MCP host.
  @host_path "/core-pages-host"

  setup_all do
    base_dir = Path.join(@work_dir, "data")
    File.rm_rf!(base_dir)
    restore = Network.configure(base_dir)
    :ok = Network.seed(base_dir, DateTime.utc_now())
    builds_dir = Builds.build(Path.join(@work_dir, "builds"))

    on_exit(fn ->
      Builds.install(builds_dir, :javascript)
      restore.()
    end)

    %{builds_dir: builds_dir}
  end

  for {scenario, title} <- [
        trip_depart_at: "a trip plan leaving at a time",
        trip_arrive_by: "a trip plan arriving by a time",
        board_for_time: "an arrivals board for a time",
        mcp_board: "an MCP arrivals board",
        offline: "the scheduled markers and a stop's arrivals offline"
      ] do
    test "#{title} renders the same on both cores", context do
      compare(
        context,
        scenario(unquote(scenario), DateTime.truncate(DateTime.utc_now(), :second))
      )
    end
  end

  defp compare(context, scenario) do
    runs = Enum.reduce(Builds.cores(), [], &[run(context, scenario, &1, &2) | &2])
    [{_reference_core, _reference_conn, reference} | others] = Enum.reverse(runs)

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
  end

  # Runs `scenario` on the build of `core`; a page that never reaches what
  # the scenario waits for fails with the browser, scenario, and core, and
  # keeps the traces of this run and of the runs before it.
  defp run(context, scenario, core, earlier) do
    Builds.install(context.builds_dir, core)
    conn = CorePages.open_session(context, scenario)

    try do
      {core, conn, scenario.run.(conn)}
    rescue
      error in ExUnit.AssertionError ->
        sessions =
          for {run_core, run_conn, _regions} <- [{core, conn, nil} | earlier],
              do: {label(context, scenario, run_core), run_conn}

        traces = CorePages.keep_traces(sessions, @trace_dir)

        flunk(
          "#{context.browser_pool} · #{scenario.name} · #{core}: #{error.message}\nTraces:\n" <>
            Enum.join(traces, "\n")
        )
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

  defp scenario(:trip_depart_at, pinned_at) do
    %{
      name: "trip plan, depart at",
      pinned_at: pinned_at,
      favorites: [],
      run:
        &plan_trip(&1, %{mode: "Depart at", clock: "08:10", window: "Leaving at 8:10 am tomorrow"})
    }
  end

  defp scenario(:trip_arrive_by, pinned_at) do
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

  defp scenario(:board_for_time, pinned_at) do
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
  defp scenario(:mcp_board, pinned_at) do
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

  defp scenario(:offline, pinned_at) do
    %{
      name: "offline markers and arrivals",
      pinned_at: pinned_at,
      favorites: [%{"stopId" => @board_stop_id, "name" => Network.stop_name(@board_stop_id)}],
      run: &start_offline/1
    }
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
    |> select("Tomorrow", from: "Day")
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
    |> reload()
    |> CorePages.await_page(offline_saved(), @offline_timeout_ms)

    try do
      :ok = Server.stop()

      conn
      |> reload()
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

  defp reload(conn), do: PhoenixTest.Playwright.reload_page(conn, timeout: @load_timeout_ms)

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
  # first two predicted, fetched at `fetched_at`.
  defp seed_arrivals(fetched_at) do
    fetched_ms = DateTime.to_unix(fetched_at, :millisecond)

    arrivals =
      for {minutes, index} <- Enum.with_index([3, 9, 13, 19, 23, 29]) do
        scheduled_ms = fetched_ms + minutes * 60_000
        predicted = index < 2

        %{
          trip_id: "1_10_0_#{index}",
          service_date_ms: fetched_ms,
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
          predicted_arrival_time_ms: if(predicted, do: scheduled_ms + 60_000),
          predicted_departure_time_ms: if(predicted, do: scheduled_ms + 60_000),
          vehicle_id: nil,
          vehicle_schedule_deviation_seconds: nil
        }
      end

    record =
      ArrivalBatch.Records.build(%{
        stop_id: @board_stop_id,
        destination:
          "raw/oba/arrivals-and-departures-for-stop/dt=2026-11-18/stop=1_1003/file.json.gz",
        fetched_at: fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: Gobusgo.RequestId.generate(),
        arrivals: arrivals
      })

    FetchView.apply_records(Gobusgo.OneBusAway.ArrivalView, [record.value])
  end
end
