defmodule Gobusgo.OneBusAway.RouteScheduleCycleTest do
  # Drives run/2 against a route view and a schedule view started for the
  # test, with a Req.Test stub that answers each route its own way and with
  # writer and publisher doubles defined here. What a cycle fetched is read
  # from the destinations the writer double reports, in order, from the
  # returned counts, and from the dates the schedule view knows afterward.
  # The log case counts the lines of a whole capture, which holds the lines
  # of every test running at the time, hence the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteScheduleCycle
  alias Gobusgo.OneBusAway.RouteScheduleView
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
  @stub_name RouteScheduleCycle
  @gate Module.concat(__MODULE__, Gate)
  @tasks Module.concat(__MODULE__, Tasks)
  @settings %Gobusgo.Config.OneBusAway{
    base_url: "https://oba.example.test",
    api_key: "test-key-3f9a1c07be52"
  }
  # The last second of the UTC day, after every route's slot, so every
  # route wants the day before, the day, and the day after.
  @now ~U[2026-11-07 23:59:59Z]

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup context do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    route_view = Module.concat(__MODULE__, "RouteView#{context.line}")
    schedule_view = Module.concat(__MODULE__, "ScheduleView#{context.line}")

    start_supervised!(
      {FetchView,
       name: route_view, pubsub: Gobusgo.PubSub, records: RouteBatch.Records, id_count_max: 8}
    )

    start_supervised!({RouteScheduleView, name: schedule_view, route_count_max: 8})

    RouteViewSeeds.routes(route_view, %{
      agency_id: "40",
      route_ids: ["40_A", "40_B"],
      fetched_at: @now
    })

    stub(%{})
    %{route_view: route_view, schedule_view: schedule_view}
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # Answers a route with the schedule fixture written for it. `answers` maps
  # a route to another answer: `{status, fixture}`.
  defp stub(answers) do
    Req.Test.stub(@stub_name, fn conn ->
      "/api/where/schedule-for-route/" <> file = conn.request_path
      route_id = String.replace_suffix(file, ".json", "")

      {status, body} =
        case Map.get(answers, route_id) do
          nil ->
            {200, String.replace(fixture("schedule_for_route"), ~s("19_41"), ~s("#{route_id}"))}

          {status, name} ->
            {status, fixture(name)}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp run(context, options \\ []) do
    defaults = [
      task_supervisor: @tasks,
      agency_ids: fn -> ["40"] end,
      route_view: context.route_view,
      schedule_view: context.schedule_view,
      clock: fn -> @now end,
      request_interval_ms: 0,
      record_options: [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, retry_delay_ms_base: 1],
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: [backend: StubPublisher, result: :ok]
      ]
    ]

    RouteScheduleCycle.run(@settings, Keyword.merge(defaults, options))
  end

  # What the cycle stored, in order: `<route>/<service date>`.
  defp written(items \\ []) do
    receive do
      {:written, destination} ->
        [route, date] =
          Regex.run(~r{route=([^/]+)/service-date=([^/]+)}, destination, capture: :all_but_first)

        written([route <> "/" <> date | items])
    after
      0 -> Enum.reverse(items)
    end
  end

  test "records the three dates of each route, routes in order and each route's earliest first",
       context do
    assert {:ok, %{due_count: 6, recorded_count: 6}} = run(context)

    assert written() == [
             "40_A/2026-11-06",
             "40_A/2026-11-07",
             "40_A/2026-11-08",
             "40_B/2026-11-06",
             "40_B/2026-11-07",
             "40_B/2026-11-08"
           ]
  end

  test "notes each recorded date, so the next cycle finds nothing due", context do
    {:ok, _counts} = run(context)
    _first = written()

    assert {:ok, %{due_count: 0}} = run(context)
    assert written() == []
  end

  test "counts a date without service and does not fetch it again", context do
    stub(%{"40_B" => {200, "schedule_for_route_no_service"}})

    assert {:ok, %{recorded_count: 3, no_service_count: 3}} = run(context)
    _first = written()

    assert {:ok, %{due_count: 0}} = run(context)
  end

  test "takes at most the request bound and defers the rest", context do
    assert {:ok, %{recorded_count: 2, deferred_count: 4}} = run(context, request_count_max: 2)
    assert written() == ["40_A/2026-11-06", "40_A/2026-11-07"]
  end

  test "counts the routes whose next date is ready once the cycle ends", context do
    stub(%{"40_B" => {200, "schedule_for_route_no_service"}})

    assert {:ok, %{route_count: 2, next_date_ready_count: 2}} = run(context)
  end

  test "leaves a date whose fetch failed due for the next cycle", context do
    stub(%{"40_A" => {500, "schedule_for_route_no_service"}})

    assert {:ok, %{recorded_count: 3, failed_count: 3}} = run(context)
    _first = written()

    stub(%{})

    assert {:ok, %{due_count: 3, recorded_count: 3}} = run(context)
    assert written() == ["40_A/2026-11-06", "40_A/2026-11-07", "40_A/2026-11-08"]
  end

  test "fails when every fetch tried fails", context do
    stub(%{
      "40_A" => {500, "schedule_for_route_no_service"},
      "40_B" => {500, "schedule_for_route_no_service"}
    })

    assert run(context) == {:error, :nothing_recorded}
  end

  test "finds nothing due before the route view holds a route", context do
    assert {:ok, %{due_count: 0, route_count: 0}} = run(context, agency_ids: fn -> [] end)
  end

  test "logs one line when the cycle finishes", context do
    log = capture_log(fn -> run(context) end)

    assert length(String.split(log, "OneBusAway route schedule cycle finished")) == 2
  end
end
