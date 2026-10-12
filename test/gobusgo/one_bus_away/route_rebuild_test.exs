defmodule Gobusgo.OneBusAway.RouteRebuildTest do
  # Stores route responses through the writer in a temporary directory, the
  # form the recorders write, runs a rebuild against route views started for
  # the test, and observes what the views hold, what readiness answers, and
  # what the run returns and logs. The log cases read a whole capture, hence
  # the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.Readiness
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RouteRebuild
  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Publisher.InProcess
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixtures Path.expand("../../fixtures/one_bus_away", __DIR__)
  @agency_id "40"
  @route_id "40_SNDR_EV"
  @now ~U[2026-10-05 12:00:00Z]
  @today ~U[2026-10-05 01:17:31Z]
  @yesterday ~U[2026-10-04 23:10:00Z]
  @long_ago ~U[2026-10-02 08:00:00Z]

  defmodule SlowReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options) do
      Process.sleep(:infinity)
    end
  end

  defmodule FailingDiscovery do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:error, :io_failure}
  end

  setup context do
    views = %{
      route_view: Module.concat(__MODULE__, "RouteView#{context.line}"),
      route_path_view: Module.concat(__MODULE__, "RoutePathView#{context.line}"),
      stop_view: Module.concat(__MODULE__, "StopView#{context.line}")
    }

    for {view, records} <- [
          {views.route_view, RouteBatch.Records},
          {views.route_path_view, RoutePathBatch.Records}
        ] do
      start_supervised!(
        {FetchView, name: view, pubsub: Gobusgo.PubSub, records: records, id_count_max: 100}
      )
    end

    start_supervised!(
      {StopView,
       name: views.stop_view, pubsub: Gobusgo.PubSub, route_count_max: 100, stop_count_max: 1_000}
    )

    subscribers = %{
      "oba.routes.state" =>
        {FetchView, :apply_records_to_each, [[views.route_view, views.route_path_view]]},
      "oba.stops.state" => {StopView, :apply_records, [views.stop_view]}
    }

    options = [
      now: fn -> @now end,
      read_options: [base_dir: context.tmp_dir],
      publish_options: [backend: InProcess, subscribers: subscribers]
    ]

    Map.put(views, :options, options)
  end

  # One route of the agency, so that the one stored path fills the views.
  defp routes_envelope do
    envelope = @fixtures |> Path.join("routes_for_agency.json") |> File.read!() |> JSON.decode!()
    [route] = Enum.filter(envelope["data"]["list"], &(&1["id"] == @route_id))
    put_in(envelope, ["data", "list"], [route])
  end

  defp route_path_envelope do
    @fixtures
    |> Path.join("stops_for_route.json")
    |> File.read!()
    |> String.replace("1_100336", @route_id)
    |> JSON.decode!()
  end

  defp response(envelope, fetched_at) do
    %{
      envelope: envelope,
      fetched_at: fetched_at,
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }
  end

  defp request_id(index) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(index), 12, "0")
  end

  defp store_routes(context, fetched_at, index \\ 1) do
    stored =
      RawRouteResponse.build(%{
        request_id: request_id(index),
        response:
          routes_envelope()
          |> response(fetched_at)
          |> Map.merge(%{agency_id: @agency_id, routes: nil})
      })

    :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: context.tmp_dir)
    stored.destination
  end

  defp store_route_path(context, fetched_at, index \\ 2) do
    stored =
      RawRoutePathResponse.build(%{
        request_id: request_id(index),
        response:
          route_path_envelope()
          |> response(fetched_at)
          |> Map.merge(%{route_id: @route_id, route_path: nil})
      })

    :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: context.tmp_dir)
    stored.destination
  end

  defp readiness(context) do
    Readiness.read(
      agency_fetch: fn -> %{agency_ids: [@agency_id]} end,
      route_view: context.route_view,
      route_path_view: context.route_path_view
    )
  end

  describe "run/1 with stored responses" do
    test "leaves the node ready with no fetch from the source", context do
      store_routes(context, @today)
      store_route_path(context, @today)

      RouteRebuild.run(context.options)

      assert readiness(context) == :ready
    end

    test "fills the route view with the routes of the stored response", context do
      store_routes(context, @today)

      RouteRebuild.run(context.options)

      assert %{route_ids: [@route_id]} = FetchView.current_fetch(context.route_view, @agency_id)
    end

    test "fills the stop view with the stops of the stored path", context do
      store_route_path(context, @today)

      RouteRebuild.run(context.options)

      assert StopView.stop_count(context.stop_view) > 0
    end

    test "keeps the time of the fetch, so the item is due when its slot next comes", context do
      store_route_path(context, @today)

      RouteRebuild.run(context.options)

      assert FetchView.fetch_times(context.route_path_view) == %{@route_id => @today}

      refute RouteSchedule.due?(%{
               id: @route_id,
               fetched_at: @today,
               now: RouteSchedule.slot_at(@route_id, @today)
             })
    end

    test "takes the newest response of an item within a day", context do
      store_route_path(context, ~U[2026-10-05 00:10:00Z], 2)
      store_route_path(context, @today, 3)

      RouteRebuild.run(context.options)

      assert %{request_id: request_id, fetched_at: @today} =
               FetchView.current_fetch(context.route_path_view, @route_id)

      assert request_id == request_id(3)
    end

    test "takes the response of the day before for an item today holds none of", context do
      store_route_path(context, @yesterday)

      RouteRebuild.run(context.options)

      assert FetchView.fetch_times(context.route_path_view) == %{@route_id => @yesterday}
    end

    test "returns the count processed per dataset", context do
      store_routes(context, @today)
      store_route_path(context, @today)

      assert RouteRebuild.run(context.options) == %{
               routes: %{processed_count: 1, failed_count: 0, undiscovered_day_count: 0},
               route_paths: %{processed_count: 1, failed_count: 0, undiscovered_day_count: 0}
             }
    end

    test "logs one info line with the counts", context do
      store_routes(context, @today)

      log = capture_log(fn -> RouteRebuild.run(context.options) end)

      assert log =~ "[info] Route views rebuilt"
      refute log =~ "Route views rebuilt incomplete"
    end
  end

  describe "run/1 with nothing to rebuild from" do
    test "leaves the item to the route cycles when no response is stored", context do
      RouteRebuild.run(context.options)

      assert readiness(context) == {:filling, {:route_items_unattempted, 1}}
    end

    test "leaves out a response older than the days it looks back", context do
      store_route_path(context, @long_ago)

      RouteRebuild.run(context.options)

      assert FetchView.fetch_times(context.route_path_view) == %{}
    end

    test "leaves the item to the route cycles when its response is unreadable", context do
      destination = store_routes(context, @today)
      File.write!(Path.join(context.tmp_dir, destination), "not gzip")

      result = RouteRebuild.run(context.options)

      assert result.routes == %{processed_count: 0, failed_count: 1, undiscovered_day_count: 0}
      assert readiness(context) == {:filling, {:route_items_unattempted, 1}}
    end

    test "leaves the item to the route cycles when its response fails to process", context do
      destination = store_routes(context, @today)
      File.write!(Path.join(context.tmp_dir, destination), :zlib.gzip(~s({"meta":{}})))

      result = RouteRebuild.run(context.options)

      assert result.routes == %{processed_count: 0, failed_count: 1, undiscovered_day_count: 0}
      assert FetchView.current(context.route_view) == []
    end

    test "processes the other responses beside one that fails", context do
      destination = store_routes(context, @today)
      File.write!(Path.join(context.tmp_dir, destination), "not gzip")
      store_route_path(context, @today)

      result = RouteRebuild.run(context.options)

      assert result.route_paths.processed_count == 1
    end

    test "logs one warning line for a run with a failure", context do
      destination = store_routes(context, @today)
      File.write!(Path.join(context.tmp_dir, destination), "not gzip")

      log = capture_log(fn -> RouteRebuild.run(context.options) end)

      assert log =~ "[warning] Route views rebuilt incomplete"
    end

    test "counts the days whose discovery fails", context do
      options = Keyword.put(context.options, :read_options, backend: FailingDiscovery)

      assert %{routes: %{undiscovered_day_count: 2}, route_paths: %{undiscovered_day_count: 2}} =
               RouteRebuild.run(options)
    end
  end

  describe "start_link/1" do
    setup do
      %{task_supervisor: start_supervised!(Task.Supervisor)}
    end

    test "returns :ignore once the views are rebuilt", context do
      store_route_path(context, @today)
      options = Keyword.put(context.options, :task_supervisor, context.task_supervisor)

      assert RouteRebuild.start_link(options) == :ignore
      assert FetchView.fetch_times(context.route_path_view) == %{@route_id => @today}
    end

    test "returns :ignore at its time limit and leaves the items due", context do
      options =
        Keyword.merge(context.options,
          task_supervisor: context.task_supervisor,
          deadline_ms: 20,
          read_options: [backend: SlowReader]
        )

      log = capture_log(fn -> assert RouteRebuild.start_link(options) == :ignore end)

      assert log =~ "Route views rebuild stopped"
      assert readiness(context) == {:filling, {:route_items_unattempted, 1}}
      assert Task.Supervisor.children(context.task_supervisor) == []
    end

    test "returns :ignore when the rebuild crashes", context do
      options =
        Keyword.merge(context.options,
          task_supervisor: context.task_supervisor,
          now: fn -> raise "no clock" end
        )

      log = capture_log(fn -> assert RouteRebuild.start_link(options) == :ignore end)

      assert log =~ "Route views rebuild stopped"
    end
  end
end
