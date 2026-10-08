defmodule Gobusgo.OneBusAway.RouteCycleTest do
  # Drives run/2 against two fetch views started and filled for the test,
  # with a Req.Test stub that answers each request path its own way and with
  # writer and publisher doubles defined here. What a cycle fetched is read
  # from the destinations the writer double reports, in order, and from the
  # returned counts, with no network access and no storage. The log cases
  # count the lines of a whole capture, which holds the lines of every test
  # running at the time, hence the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteCycle
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.Test.RouteViewSeeds

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination})
      :ok
    end
  end

  defmodule StubPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, options), do: Keyword.fetch!(options, :result)
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RouteCycle
  @gate Module.concat(__MODULE__, Gate)
  @tasks Module.concat(__MODULE__, Tasks)
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}
  @now ~U[2026-10-05 12:00:00Z]
  @fresh @now
  @stale ~U[2026-10-03 12:00:00Z]

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup context do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    route_view = Module.concat(__MODULE__, "RouteView#{context.line}")
    route_path_view = Module.concat(__MODULE__, "RoutePathView#{context.line}")

    for {view, records} <- [
          {route_view, RouteBatch.Records},
          {route_path_view, RoutePathBatch.Records}
        ] do
      start_supervised!(
        {FetchView, name: view, pubsub: Gobusgo.PubSub, records: records, id_count_max: 100}
      )
    end

    stub(%{})
    %{route_view: route_view, route_path_view: route_path_view}
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # Answers a request with the fixture of its method, written for the agency
  # or the route the path names. `answers` maps an identifier to another
  # answer: `{status, fixture}` or `:stall`.
  defp stub(answers) do
    Req.Test.stub(@stub_name, fn conn ->
      {name, id, body} =
        case conn.request_path do
          "/api/where/routes-for-agency/" <> file ->
            id = String.replace_suffix(file, ".json", "")
            {"routes_for_agency", id, fn text -> String.replace(text, ~s("40"), ~s("#{id}")) end}

          "/api/where/stops-for-route/" <> file ->
            id = String.replace_suffix(file, ".json", "")
            {"stops_for_route", id, fn text -> String.replace(text, "1_100336", id) end}
        end

      case Map.get(answers, id, {200, name}) do
        :stall ->
          Process.sleep(:infinity)

        {status, ^name} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, body.(fixture(name)))

        {status, other} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, fixture(other))
      end
    end)
  end

  defp seed_routes(%{route_view: view}, agency_id, route_ids, fetched_at) do
    RouteViewSeeds.routes(view, %{
      agency_id: agency_id,
      route_ids: route_ids,
      fetched_at: fetched_at
    })
  end

  defp seed_route_path(%{route_path_view: view}, route_id, fetched_at) do
    RouteViewSeeds.route_path(view, %{route_id: route_id, fetched_at: fetched_at})
  end

  defp run(context, agency_ids, options \\ []) do
    defaults = [
      task_supervisor: @tasks,
      agency_ids: fn -> agency_ids end,
      route_view: context.route_view,
      route_path_view: context.route_path_view,
      clock: fn -> @now end,
      request_interval_ms: 0,
      record_options: [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, retry_delay_ms_base: 1],
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: [backend: StubPublisher, result: :ok]
      ]
    ]

    RouteCycle.run(@settings, Keyword.merge(defaults, options))
  end

  # What the cycle stored, in order: `agency=<id>` or `route=<id>`.
  defp written(items \\ []) do
    receive do
      {:written, destination} ->
        [item] = Regex.run(~r{(?:agency|route)=[^/]+}, destination)
        written(items ++ [item])
    after
      0 -> items
    end
  end

  @nothing %{
    due_count: 0,
    recorded_count: 0,
    failed_count: 0,
    skipped_count: 0,
    deferred_count: 0,
    unannounced_count: 0
  }

  describe "run/2 what is due" do
    test "fetches nothing when there is no agency", context do
      assert run(context, []) == {:ok, @nothing}
      assert written() == []
    end

    test "fetches the routes of every agency that has none, in identifier order", context do
      assert run(context, ["40", "1"]) == {:ok, %{@nothing | due_count: 2, recorded_count: 2}}
      assert written() == ["agency=1", "agency=40"]
    end

    test "fetches the paths of every route that has none, in identifier order", context do
      seed_routes(context, "40", ["40_2", "40_1"], @fresh)

      assert run(context, ["40"]) == {:ok, %{@nothing | due_count: 2, recorded_count: 2}}
      assert written() == ["route=40_1", "route=40_2"]
    end

    test "fetches due agencies before due routes", context do
      seed_routes(context, "40", ["40_1"], @stale)

      assert {:ok, %{due_count: 2, recorded_count: 2}} = run(context, ["40"])
      assert written() == ["agency=40", "route=40_1"]
    end

    test "fetches nothing when every agency and route has a fetch since its slot", context do
      seed_routes(context, "40", ["40_1"], @fresh)
      seed_route_path(context, "40_1", @fresh)

      assert run(context, ["40"]) == {:ok, @nothing}
      assert written() == []
    end

    test "fetches a route path made before the route's latest slot", context do
      seed_routes(context, "40", ["40_1", "40_2"], @fresh)
      seed_route_path(context, "40_1", @stale)
      seed_route_path(context, "40_2", @fresh)

      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["40"])
      assert written() == ["route=40_1"]
    end

    test "leaves out the routes of an agency that is not among the agencies", context do
      seed_routes(context, "40", ["40_1"], @fresh)
      seed_routes(context, "1", ["1_1"], @fresh)

      assert {:ok, %{due_count: 1}} = run(context, ["40"])
      assert written() == ["route=40_1"]
    end
  end

  describe "run/2 bounds and pace" do
    test "takes at most the request count and defers the rest", context do
      seed_routes(context, "40", ["40_1", "40_2", "40_3"], @fresh)

      assert run(context, ["40"], request_count_max: 2) ==
               {:ok, %{@nothing | due_count: 3, recorded_count: 2, deferred_count: 1}}

      assert written() == ["route=40_1", "route=40_2"]
    end

    test "waits out the interval between one request and the next", context do
      seed_routes(context, "40", ["40_1", "40_2", "40_3"], @fresh)
      test_pid = self()

      assert {:ok, %{recorded_count: 3}} =
               run(context, ["40"],
                 request_interval_ms: 1_000,
                 sleep: fn wait_ms -> send(test_pid, {:slept, wait_ms}) end
               )

      assert_received {:slept, first}
      assert_received {:slept, second}
      refute_received {:slept, _third}
      assert first in 1..1_000
      assert second in 1..1_000
    end

    test "starts no request with too little of the budget left", context do
      seed_routes(context, "40", ["40_1", "40_2"], @fresh)

      assert run(context, ["40"], budget_ms: 100) ==
               {:ok, %{@nothing | due_count: 2, skipped_count: 2}}

      assert written() == []
    end

    test "counts the items the budget did not reach as skipped", context do
      seed_routes(context, "40", ["40_1", "40_2", "40_3"], @fresh)
      stub(%{"40_2" => :stall})

      assert {:ok, %{due_count: 3, recorded_count: 1, failed_count: 1, skipped_count: 1}} =
               run(context, ["40"], budget_ms: 600, request_deadline_ms: 5_000)
    end
  end

  describe "run/2 failures" do
    for {label, answer} <- [
          {"answers with a server error", {500, "server_error"}},
          {"is unknown to the server", {404, "unauthorized"}},
          {"raises on a broken schema", {200, "stops_for_route_schema_violation"}}
        ] do
      test "goes on to the next item when one #{label}", context do
        seed_routes(context, "40", ["40_1", "40_2", "40_3"], @fresh)
        stub(%{"40_2" => unquote(Macro.escape(answer))})

        assert {:ok, %{due_count: 3, recorded_count: 2, failed_count: 1}} = run(context, ["40"])
        assert written() == ["route=40_1", "route=40_3"]
      end
    end

    test "goes on to the next item when one stalls past its deadline", context do
      seed_routes(context, "40", ["40_1", "40_2"], @fresh)
      stub(%{"40_1" => :stall})

      assert {:ok, %{recorded_count: 1, failed_count: 1}} =
               run(context, ["40"], request_deadline_ms: 50)

      assert written() == ["route=40_2"]
    end

    test "returns an error when items are due and none is recorded", context do
      stub(%{"40" => {500, "server_error"}})

      assert run(context, ["40"]) == {:error, :nothing_recorded}
    end

    test "counts a stored response whose event was not published", context do
      options = [
        record_options: [
          fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
          write_options: [backend: RecordingBackend, recipient: self()],
          publish_options: [backend: StubPublisher, result: {:error, :unavailable}]
        ]
      ]

      assert {:ok, %{recorded_count: 1, unannounced_count: 1}} = run(context, ["40"], options)
    end
  end

  # The publisher double announces a response and hands it to nobody, so a
  # recorded response reaches no view here.
  describe "run/2 a recorded response that does not reach its view" do
    test "is not fetched again before its slot comes", context do
      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["40"])

      assert run(context, ["40"]) == {:ok, @nothing}
      assert written() == ["agency=40"]
    end

    test "is fetched again once its slot has come", context do
      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["40"])
      later = DateTime.add(DateTime.utc_now(), 2, :day)

      assert {:ok, %{due_count: 1, recorded_count: 1}} =
               run(context, ["40"], clock: fn -> later end)
    end

    test "stays due when its event was not published", context do
      options = [
        record_options: [
          fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
          write_options: [backend: RecordingBackend, recipient: self()],
          publish_options: [backend: StubPublisher, result: {:error, :unavailable}]
        ]
      ]

      assert {:ok, %{due_count: 1, unannounced_count: 1}} = run(context, ["40"], options)
      assert {:ok, %{due_count: 1, unannounced_count: 1}} = run(context, ["40"], options)
    end
  end

  describe "run/2 logging" do
    for {name, level, message, arrange} <- [
          {"nothing due", :debug, "OneBusAway route cycle found nothing due", quote(do: %{})},
          {"every item recorded", :info, "OneBusAway route cycle finished", quote(do: %{})},
          {"some items failed", :warning, "OneBusAway route cycle finished degraded",
           quote(do: %{"40_1" => {500, "server_error"}})},
          {"every item failed", :error, "OneBusAway route cycle failed",
           quote(do: %{"40_1" => {500, "server_error"}, "40_2" => {500, "server_error"}})}
        ] do
      test "logs once at #{level} for #{name}", context do
        if unquote(name) != "nothing due" do
          seed_routes(context, "40", ["40_1", "40_2"], @fresh)
        end

        stub(unquote(arrange))
        agency_ids = if unquote(name) == "nothing due", do: [], else: ["40"]

        log = capture_log([level: unquote(level)], fn -> run(context, agency_ids) end)

        assert length(String.split(log, unquote(message))) == 2
        assert log =~ "[#{unquote(level)}]"
      end
    end
  end
end
