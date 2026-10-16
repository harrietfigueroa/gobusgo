defmodule Gobusgo.OneBusAway.ArrivalCycleTest do
  # Drives run/2 against an arrivals view started and filled for the test,
  # with the open stops given as a list, a Req.Test stub that answers each
  # stop its own way, and writer and publisher doubles defined here. What a
  # cycle fetched is read from the destinations the writer double reports,
  # in order, and from the returned counts, with no network access and no
  # storage. The log cases count the lines of a whole capture, which holds
  # the lines of every test running at the time, hence the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.ArrivalCycle
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.DemandKey

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
  @fixture_name "arrivals_and_departures_for_stop"
  @fixture_stop_id "95_7"
  @stub_name ArrivalCycle
  @gate Module.concat(__MODULE__, Gate)
  @tasks Module.concat(__MODULE__, Tasks)
  @settings %Gobusgo.Config.OneBusAway{
    base_url: "https://oba.example.test",
    api_key: "test-key-3f9a1c07be52"
  }
  @now ~U[2026-10-07 02:30:00Z]
  @fresh DateTime.add(@now, -60, :second)
  @stale DateTime.add(@now, -600, :second)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @proportional {:proportional,
                 %{interval_ms_min: 30_000, interval_ms_max: 300_000, item_spacing_ms: 5_000}}

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup context do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {FetchView,
       name: view, pubsub: Gobusgo.PubSub, records: ArrivalBatch.Records, id_count_max: 100}
    )

    stub(%{})
    %{view: view}
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # Answers a request with the fixture, written for the stop the path names.
  # `answers` maps a stop to another answer: `{status, fixture}` or `:stall`.
  defp stub(answers) do
    Req.Test.stub(@stub_name, fn conn ->
      "/api/where/arrivals-and-departures-for-stop/" <> file = conn.request_path
      stop_id = String.replace_suffix(file, ".json", "")

      case Map.get(answers, stop_id, {200, @fixture_name}) do
        :stall ->
          Process.sleep(:infinity)

        {status, name} ->
          body = String.replace(fixture(name), ~s("#{@fixture_stop_id}"), ~s("#{stop_id}"))

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, body)
      end
    end)
  end

  defp seed(%{view: view}, stop_id, fetched_at) do
    record =
      ArrivalBatch.Records.build(%{
        stop_id: stop_id,
        destination: "raw/oba/arrivals-and-departures-for-stop/seeded.json.gz",
        fetched_at: fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: @request_id,
        arrivals: []
      })

    :ok = FetchView.apply_records(view, [record.value])
  end

  # The options every case shares, with the cycle's own request count.
  defp base_options(context, stop_ids) do
    [
      task_supervisor: @tasks,
      stop_ids: fn -> stop_ids end,
      arrival_view: context.view,
      clock: fn -> @now end,
      request_interval_ms: 0,
      record_options: [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, retry_delay_ms_base: 1],
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: [backend: StubPublisher, result: :ok]
      ]
    ]
  end

  # A cycle that takes every due stop unless `options` say otherwise.
  defp run(context, stop_ids, options \\ []) do
    defaults = Keyword.put(base_options(context, stop_ids), :request_count_max, 10)

    ArrivalCycle.run(@settings, Keyword.merge(defaults, options))
  end

  # The stops the cycle stored a response of, in order.
  defp written(stop_ids \\ []) do
    receive do
      {:written, destination} ->
        [_segment, stop_id] = Regex.run(~r{stop=([^/]+)}, destination)
        written(stop_ids ++ [stop_id])
    after
      0 -> stop_ids
    end
  end

  @nothing %{
    open_count: 0,
    due_count: 0,
    recorded_count: 0,
    failed_count: 0,
    skipped_count: 0,
    deferred_count: 0,
    unannounced_count: 0
  }

  describe "run/2 what is due" do
    test "fetches nothing when no stop is open", context do
      seed(context, "1_100", @stale)

      assert run(context, []) == {:ok, @nothing}
      assert written() == []
    end

    test "fetches an open stop that has no fetch", context do
      assert run(context, ["1_100"]) ==
               {:ok, %{@nothing | open_count: 1, due_count: 1, recorded_count: 1}}

      assert written() == ["1_100"]
    end

    test "leaves an open stop whose fetch is fresh", context do
      seed(context, "1_100", @fresh)

      assert run(context, ["1_100"]) == {:ok, %{@nothing | open_count: 1}}
      assert written() == []
    end

    test "fetches an open stop whose fetch is five minutes old", context do
      seed(context, "1_100", DateTime.add(@now, -300, :second))

      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["1_100"])
    end

    # Each row is a count of open stops and whether the one of them fetched
    # a minute ago is fetched again, under a policy of 5,000 ms a stop from
    # 30,000 ms up. Every other stop has a fetch a second old, which no row
    # makes due.
    for {open_count, refresh_age_ms, written} <- [
          {3, 30_000, ["1_1"]},
          {12, 60_000, ["1_1"]},
          {13, 65_000, []},
          {20, 100_000, []}
        ] do
      test "with #{open_count} stops open, a fetch a minute old meets a refresh age of #{refresh_age_ms} ms",
           context do
        stop_ids = for index <- 1..unquote(open_count), do: "1_#{index}"
        seed(context, "1_1", @fresh)
        for stop_id <- tl(stop_ids), do: seed(context, stop_id, DateTime.add(@now, -1, :second))

        assert {:ok, %{open_count: unquote(open_count)}} =
                 run(context, stop_ids, refresh_policy: @proportional)

        assert written() == unquote(written)
      end
    end

    test "counts the open stops it schedules from as the policy's items", context do
      test_pid = self()

      stop_ids = fn ->
        send(test_pid, :open_stops_read)
        for index <- 1..12, do: "1_#{index}"
      end

      seed(context, "1_1", @fresh)

      assert {:ok, %{open_count: 12, due_count: 12}} =
               run(context, [], stop_ids: stop_ids, refresh_policy: @proportional)

      assert_received :open_stops_read
      refute_received :open_stops_read
    end

    test "applies a fixed age of five minutes unless given a policy", context do
      seed(context, "1_100", DateTime.add(@now, -299, :second))

      assert run(context, ["1_100"]) == {:ok, %{@nothing | open_count: 1}}
    end

    test "raises for a refresh policy of an unknown shape", context do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        run(context, ["1_100"], refresh_policy: {:unknown, 30_000})
      end
    end

    test "fetches the stops with no fetch before the stale ones, the oldest first", context do
      seed(context, "1_100", @stale)
      seed(context, "1_200", DateTime.add(@stale, -60, :second))

      assert {:ok, %{open_count: 3, due_count: 3, recorded_count: 3}} =
               run(context, ["1_100", "1_200", "1_300"])

      assert written() == ["1_300", "1_200", "1_100"]
    end

    test "leaves a stop no process has open, however old its fetch", context do
      seed(context, "1_999", @stale)

      assert {:ok, %{open_count: 1, due_count: 1}} = run(context, ["1_100"])
      assert written() == ["1_100"]
    end

    test "reads the open stops of the registry it is given", context do
      registry = Module.concat(__MODULE__, "Registry#{context.line}")
      start_supervised!({Demand, name: registry, datasets: DemandKey.datasets()})
      stop_ids = fn -> Demand.items(registry, DemandKey.arrivals_dataset()) end
      :ok = Demand.register(registry, DemandKey.arrivals("1_100"))

      assert {:ok, %{open_count: 1, recorded_count: 1}} =
               run(context, [], stop_ids: stop_ids)

      :ok = Demand.release(registry, DemandKey.arrivals("1_100"))

      assert {:ok, %{open_count: 0, due_count: 0}} =
               run(context, [], stop_ids: stop_ids)

      assert written() == ["1_100"]
    end
  end

  describe "run/2 bounds and pace" do
    test "takes one stop a cycle unless told otherwise, and defers the rest", context do
      options = base_options(context, ["1_100", "1_200", "1_300"])

      assert ArrivalCycle.run(@settings, options) ==
               {:ok,
                %{@nothing | open_count: 3, due_count: 3, recorded_count: 1, deferred_count: 2}}

      assert written() == ["1_100"]
    end

    test "takes at most the request count and defers the rest", context do
      assert run(context, ["1_100", "1_200", "1_300"], request_count_max: 2) ==
               {:ok,
                %{@nothing | open_count: 3, due_count: 3, recorded_count: 2, deferred_count: 1}}

      assert written() == ["1_100", "1_200"]
    end

    test "waits out the interval between one request and the next", context do
      test_pid = self()

      assert {:ok, %{recorded_count: 3}} =
               run(context, ["1_100", "1_200", "1_300"],
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
      assert run(context, ["1_100", "1_200"], budget_ms: 100) ==
               {:ok, %{@nothing | open_count: 2, due_count: 2, skipped_count: 2}}

      assert written() == []
    end

    test "defers the due stops the request count does not reach at the longest refresh age",
         context do
      stop_ids = for index <- 10..70, do: "1_#{index}"
      options = Keyword.put(base_options(context, stop_ids), :refresh_policy, @proportional)

      assert ArrivalCycle.run(@settings, options) ==
               {:ok,
                %{@nothing | open_count: 61, due_count: 61, recorded_count: 1, deferred_count: 60}}

      assert written() == ["1_10"]
    end

    test "raises for more open stops than a cycle reads", context do
      stop_ids = for index <- 1..2_001, do: "1_#{index}"

      assert_raise Gobusgo.Assert.AssertionError, ~r/open stops/, fn ->
        run(context, stop_ids)
      end
    end
  end

  describe "run/2 failures" do
    for {label, answer} <- [
          {"answers with a server error", {500, "server_error"}},
          {"is unknown to the server", {404, "unauthorized"}},
          {"raises on a broken schema",
           {200, "arrivals_and_departures_for_stop_schema_violation"}}
        ] do
      test "goes on to the next stop when one #{label}", context do
        stub(%{"1_200" => unquote(Macro.escape(answer))})

        assert {:ok, %{due_count: 3, recorded_count: 2, failed_count: 1}} =
                 run(context, ["1_100", "1_200", "1_300"])

        assert written() == ["1_100", "1_300"]
      end
    end

    test "goes on to the next stop when one stalls past its deadline", context do
      stub(%{"1_100" => :stall})

      assert {:ok, %{recorded_count: 1, failed_count: 1}} =
               run(context, ["1_100", "1_200"], request_deadline_ms: 50)

      assert written() == ["1_200"]
    end

    test "returns an error when stops are due and none is recorded", context do
      stub(%{"1_100" => {500, "server_error"}})

      assert run(context, ["1_100"]) == {:error, :nothing_recorded}
    end

    test "counts a stored response whose event was not published", context do
      options = [
        record_options: [
          fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
          write_options: [backend: RecordingBackend, recipient: self()],
          publish_options: [backend: StubPublisher, result: {:error, :unavailable}]
        ]
      ]

      assert {:ok, %{recorded_count: 1, unannounced_count: 1}} =
               run(context, ["1_100"], options)
    end
  end

  # The publisher double announces a response and hands it to nobody, so a
  # recorded response reaches no view here.
  describe "run/2 a recorded response that does not reach its view" do
    test "is not fetched again before the refresh age has passed", context do
      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["1_100"])

      assert run(context, ["1_100"]) == {:ok, %{@nothing | open_count: 1}}
      assert written() == ["1_100"]
    end

    test "is fetched again once the refresh age has passed", context do
      assert {:ok, %{due_count: 1, recorded_count: 1}} = run(context, ["1_100"])
      later = DateTime.add(DateTime.utc_now(), 1, :hour)

      assert {:ok, %{due_count: 1, recorded_count: 1}} =
               run(context, ["1_100"], clock: fn -> later end)
    end

    test "stays due when its event was not published", context do
      options = [
        record_options: [
          fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
          write_options: [backend: RecordingBackend, recipient: self()],
          publish_options: [backend: StubPublisher, result: {:error, :unavailable}]
        ]
      ]

      assert {:ok, %{due_count: 1, unannounced_count: 1}} = run(context, ["1_100"], options)
      assert {:ok, %{due_count: 1, unannounced_count: 1}} = run(context, ["1_100"], options)
    end
  end

  describe "run/2 logging" do
    for {name, level, message, stop_ids, answers} <- [
          {"nothing due", :debug, "OneBusAway arrival cycle found nothing due", [], %{}},
          {"every stop recorded", :info, "OneBusAway arrival cycle finished", ["1_100", "1_200"],
           %{}},
          {"some stops failed", :warning, "OneBusAway arrival cycle finished degraded",
           ["1_100", "1_200"], %{"1_100" => {500, "server_error"}}},
          {"every stop failed", :error, "OneBusAway arrival cycle failed", ["1_100", "1_200"],
           %{"1_100" => {500, "server_error"}, "1_200" => {500, "server_error"}}}
        ] do
      test "logs once at #{level} for #{name}", context do
        stub(unquote(Macro.escape(answers)))

        log =
          capture_log([level: unquote(level)], fn -> run(context, unquote(stop_ids)) end)

        assert length(String.split(log, unquote(message))) == 2
        assert log =~ "[#{unquote(level)}]"
      end
    end

    # Each row is a refresh policy, the open stops, and the age the cycle's
    # one line has to name for them, read from the line's metadata.
    for {label, policy, open_count, refresh_age_ms} <- [
          {"the shortest age for no open stop", @proportional, 0, 30_000},
          {"the scaled age for 12 open stops", @proportional, 12, 60_000},
          {"the longest age for 61 open stops", @proportional, 61, 300_000},
          {"the age of a fixed policy", {:fixed, 45_000}, 2, 45_000}
        ] do
      test "names #{label} as refresh_age_ms", context do
        stop_ids = for index <- 1..unquote(open_count)//1, do: "1_#{index}"

        log =
          capture_log([level: :debug, metadata: :all], fn ->
            run(context, stop_ids,
              refresh_policy: unquote(Macro.escape(policy)),
              request_count_max: 1
            )
          end)

        [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "OneBusAway arrival cycle"))
        assert line =~ "refresh_age_ms=#{unquote(refresh_age_ms)} "
      end
    end

    test "names no stop", context do
      log =
        capture_log([level: :debug, metadata: :all], fn ->
          run(context, ["1_314159", "1_271828"])
        end)

      [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "OneBusAway arrival cycle"))
      refute line =~ "314159"
      refute line =~ "271828"
    end
  end
end
