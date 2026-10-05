defmodule Gobusgo.OneBusAway.RouteBackfillTest do
  # Drives run/2 with a Req.Test stub that answers each request path its own
  # way, the local file backends under a temporary directory, and a publisher
  # double defined here. What a backfill fetched is read from the requests
  # the stub reports, in order, and from the returned summary, with no
  # network access and no broker.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RouteBackfill

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule StubPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, Enum.map(records, & &1.key)})
      Keyword.fetch!(options, :result)
    end
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RouteBackfill
  @gate Module.concat(__MODULE__, Gate)
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    stub(%{})
    :ok
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # Answers a request with the fixture of its method, written for the agency
  # or the route the path names, and reports the request to the test.
  # `answers` maps an identifier to a list of other answers, one per
  # request of that identifier in order: a status with the fixture to serve.
  defp stub(answers) do
    test_pid = self()
    counts = :ets.new(:counts, [:public])

    Req.Test.stub(@stub_name, fn conn ->
      {name, id, body} =
        case conn.request_path do
          "/api/where/agencies-with-coverage.json" ->
            {"agencies_with_coverage", "agencies", & &1}

          "/api/where/routes-for-agency/" <> file ->
            id = String.replace_suffix(file, ".json", "")

            {"routes_for_agency", id,
             fn text ->
               text
               |> String.replace(~s("40"), ~s("#{id}"))
               |> String.replace(~s("40_), ~s("#{id}_))
             end}

          "/api/where/stops-for-route/" <> file ->
            id = String.replace_suffix(file, ".json", "")
            {"stops_for_route", id, &String.replace(&1, "1_100336", id)}
        end

      send(test_pid, {:requested, id})
      request_index = :ets.update_counter(counts, id, 1, {id, 0}) - 1

      {status, served} =
        answers
        |> Map.get(id, [])
        |> Enum.at(request_index)
        |> case do
          nil -> {200, body.(fixture(name))}
          {status, other} -> {status, fixture(other)}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, served)
    end)
  end

  defp run(%{tmp_dir: tmp_dir}, options \\ []) do
    defaults = [
      agency_ids: ["40"],
      request_interval_ms: 0,
      fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, retry_delay_ms_base: 1],
      write_options: [base_dir: tmp_dir],
      read_options: [base_dir: tmp_dir],
      publish_options: [backend: StubPublisher, recipient: self(), result: :ok]
    ]

    RouteBackfill.run(@settings, Keyword.merge(defaults, options))
  end

  defp requested(ids \\ []) do
    receive do
      {:requested, id} -> requested(ids ++ [id])
    after
      0 -> ids
    end
  end

  @route_ids ["40_100479", "40_100511", "40_SNDR_EV"]

  describe "run/2 what it fetches" do
    test "fetches an agency's routes and then every route's paths, in order", context do
      assert {:ok, summary} = run(context)

      assert summary == %{
               agency_count: 1,
               route_count: 3,
               recorded_count: 4,
               failed_count: 0,
               skipped_count: 0,
               unannounced_count: 0,
               retried_count: 0,
               failures: %{},
               stopped: false
             }

      assert requested() == ["40" | @route_ids]
    end

    test "stores every response and announces it", context do
      assert {:ok, %{recorded_count: 4}} = run(context)

      for key <- [
            "oba/routes-for-agency/40" | Enum.map(@route_ids, &("oba/stops-for-route/" <> &1))
          ] do
        assert_received {:published, [^key]}
      end

      stored = Path.wildcard(Path.join(context.tmp_dir, "raw/oba/**/*.json.gz"))
      assert length(stored) == 4
    end

    test "fetches the routes of every agency before any route's paths", context do
      assert {:ok, %{agency_count: 2, route_count: 6, recorded_count: 8}} =
               run(context, agency_ids: ["40", "1"])

      assert Enum.take(requested(), 2) == ["1", "40"]
    end

    test "asks the server for the agencies when none is named", context do
      assert {:ok, %{agency_count: 2}} = run(context, agency_ids: nil)

      assert ["agencies", "1", "40" | _routes] = requested()
    end

    test "returns the failure when the agencies cannot be fetched", context do
      stub(%{"agencies" => [{500, "server_error"}]})

      assert run(context, agency_ids: nil) == {:error, {:agencies, {:http_status, 500}}}
    end

    test "takes at most the route count and counts the rest as skipped", context do
      assert {:ok, %{route_count: 3, recorded_count: 3, skipped_count: 1}} =
               run(context, route_count_max: 2)

      assert requested() == ["40" | Enum.take(@route_ids, 2)]
    end
  end

  describe "report/1" do
    @summary %{
      agency_count: 12,
      route_count: 391,
      recorded_count: 400,
      failed_count: 2,
      skipped_count: 1,
      unannounced_count: 3,
      retried_count: 4,
      failures: %{"fetch:http_status" => 1, "contract_violation" => 1},
      stopped: false
    }

    test "names every count on a line of its own" do
      assert RouteBackfill.report(@summary) == """
             Route backfill finished
               agencies:            12
               routes:              391
               recorded:            400
               failed:              2
               skipped:             1
               stored, unannounced: 3
               repeated requests:   4
               failures by cause:   contract_violation 1, fetch:http_status 1\
             """
    end

    test "says so when the failure streak stopped the backfill" do
      assert RouteBackfill.report(%{@summary | stopped: true}) =~
               "Route backfill stopped after failures in a row\n"
    end

    test "says none when nothing failed" do
      assert RouteBackfill.report(%{@summary | failures: %{}}) =~ "failures by cause:   none"
    end
  end

  describe "run/2 pace" do
    test "waits out the interval between one request and the next", context do
      test_pid = self()

      assert {:ok, %{recorded_count: 4}} =
               run(context,
                 request_interval_ms: 1_000,
                 sleep: fn wait_ms -> send(test_pid, {:slept, wait_ms}) end
               )

      waits = for _request <- 1..3, do: assert_received({:slept, wait_ms}) && wait_ms
      refute_received {:slept, _fourth}
      assert Enum.all?(waits, &(&1 in 1..1_000))
    end
  end

  describe "run/2 failures" do
    test "goes on to the next route when one fails", context do
      stub(%{"40_100511" => [{500, "server_error"}]})

      assert {:ok, %{recorded_count: 3, failed_count: 1, failures: failures}} = run(context)
      assert failures == %{"fetch:http_status" => 1}
      assert requested() == ["40" | @route_ids]
    end

    test "counts a response that breaks the contract as one failed item", context do
      stub(%{"40_100511" => [{200, "stops_for_route_schema_violation"}]})

      assert {:ok, %{recorded_count: 3, failed_count: 1, failures: failures}} = run(context)
      assert failures == %{"contract_violation" => 1}
    end

    test "fetches no route of an agency whose routes cannot be fetched", context do
      stub(%{"40" => [{500, "server_error"}]})

      assert {:ok, %{agency_count: 1, route_count: 0, recorded_count: 0, failed_count: 1}} =
               run(context)

      assert requested() == ["40"]
    end

    test "tries a rate-limited request again and records it", context do
      stub(%{"40_100511" => [{429, "server_error"}, {429, "server_error"}]})

      assert {:ok, %{recorded_count: 4, failed_count: 0, retried_count: 2}} = run(context)

      assert requested() ==
               ["40", "40_100479", "40_100511", "40_100511", "40_100511", "40_SNDR_EV"]
    end

    test "gives up on a request that stays rate-limited", context do
      stub(%{"40_100511" => List.duplicate({429, "server_error"}, 3)})

      assert {:ok, %{recorded_count: 3, failed_count: 1, retried_count: 2, failures: failures}} =
               run(context)

      assert failures == %{"fetch:http_status" => 1}
    end

    test "stops after the given number of failures in a row and skips the rest", context do
      stub(%{
        "40_100479" => [{500, "server_error"}],
        "40_100511" => [{500, "server_error"}]
      })

      assert {:ok, summary} = run(context, failure_streak_max: 2)

      assert %{stopped: true, recorded_count: 1, failed_count: 2, skipped_count: 1} = summary
      assert requested() == ["40", "40_100479", "40_100511"]
    end

    test "counts a stored response whose event was not published", context do
      options = [
        publish_options: [
          backend: StubPublisher,
          recipient: self(),
          result: {:error, :unavailable}
        ]
      ]

      assert {:ok, %{recorded_count: 4, unannounced_count: 4}} = run(context, options)
    end
  end
end
