defmodule Gobusgo.Gbfs.VehicleTypesCycleTest do
  # Drives run/1 against a fetch view started for the test, with Lime
  # Seattle's recorded files served from a Req.Test stub by address, where a
  # route the case leaves out answers 404, and with the in-process publisher
  # handing the records to the test's view. What a cycle did is read from
  # the requests the stub reports, the view's fetches, and the returned
  # counts, with no network access. The log cases count the lines of a whole
  # capture, which holds the lines of every test running at the time, hence
  # the non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.Gbfs.VehicleTypeRecords
  alias Gobusgo.Gbfs.VehicleTypesCycle
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteSchedule

  @moduletag capture_log: true

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)
  @stub_name VehicleTypesCycle
  @now ~U[2026-11-08 20:00:00Z]

  @origin "https://data.lime.bike/api/partners"
  @system %{
    id: "lime_seattle",
    discovery_urls: %{
      "3.0" => @origin <> "/v3/gbfs/seattle/gbfs.json",
      "2.2" => @origin <> "/v2/gbfs/seattle/gbfs.json",
      "1.0" => @origin <> "/v1/gbfs/seattle/gbfs.json"
    },
    language: "en"
  }
  @v3_vehicle_types @origin <> "/v3/gbfs/seattle/vehicle_types.json"
  @v2_vehicle_types @origin <> "/v2/gbfs/seattle/vehicle_types"

  @routes %{
    (@origin <> "/v3/gbfs/seattle/gbfs.json") => {:fixture, "lime_v3_gbfs"},
    (@origin <> "/v2/gbfs/seattle/gbfs.json") => {:fixture, "lime_v2_gbfs"},
    (@origin <> "/v1/gbfs/seattle/gbfs.json") => {:fixture, "lime_v1_gbfs"},
    @v3_vehicle_types => {:fixture, "lime_v3_vehicle_types"},
    @v2_vehicle_types => {:fixture, "lime_v2_vehicle_types"}
  }

  @nothing %{
    due_count: 0,
    fetched_count: 0,
    not_published_count: 0,
    failed_count: 0,
    skipped_count: 0
  }

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {FetchView,
       name: view, pubsub: Gobusgo.PubSub, records: VehicleTypeRecords, id_count_max: 8}
    )

    serve(@routes)
    %{view: view}
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp serve(routes) do
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      url = "https://" <> conn.host <> conn.request_path
      send(test_pid, {:requested, url})

      case Map.fetch(routes, url) do
        {:ok, {:fixture, name}} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, fixture(name))

        {:ok, {:status, status}} ->
          Plug.Conn.send_resp(conn, status, "")

        :error ->
          Plug.Conn.send_resp(conn, 404, "<html>404 Not Found</html>")
      end
    end)
  end

  defp run(context, options \\ []) do
    defaults = [
      systems: [@system],
      view: context.view,
      clock: fn -> @now end,
      fetch_options: [plug: {Req.Test, @stub_name}],
      publish_options: [
        backend: Gobusgo.Publisher.InProcess,
        subscribers: %{
          VehicleTypeRecords.topic() => {FetchView, :apply_records, [context.view]}
        }
      ]
    ]

    VehicleTypesCycle.run(Keyword.merge(defaults, options))
  end

  # The vehicle_types files the cycle asked for, in order.
  defp requested_types(urls \\ []) do
    receive do
      {:requested, url} ->
        if url in [@v3_vehicle_types, @v2_vehicle_types] do
          requested_types(urls ++ [url])
        else
          requested_types(urls)
        end
    after
      0 -> urls
    end
  end

  defp seed(%{view: view}, version, fetched_at) do
    record =
      VehicleTypeRecords.build(%{
        system_id: @system.id,
        version: version,
        request_id: Gobusgo.RequestId.generate(),
        fetched_at: fetched_at,
        vehicle_types: []
      })

    :ok = FetchView.apply_records(view, [record.value])
  end

  defp type_ids(%{view: view}, version) do
    id = VehicleTypeRecords.id(%{system_id: @system.id, version: version})
    %{vehicle_types: types} = FetchView.current_fetch(view, id)
    types |> Map.keys() |> Enum.sort()
  end

  # The latest coming of a slot at or before `@now`, moved by `seconds`.
  defp slot_time(version, seconds) do
    id = VehicleTypeRecords.id(%{system_id: @system.id, version: version})
    id |> RouteSchedule.slot_at(@now) |> DateTime.add(seconds, :second)
  end

  test "spec/1 runs a cycle every minute with a deadline under the interval" do
    assert %{cadence: %{policy: {:fixed, 60_000}}, deadline_ms: deadline_ms} =
             VehicleTypesCycle.spec([])

    assert deadline_ms < 60_000
  end

  describe "run/1 on an empty view" do
    test "fetches the types of each version that publishes them, newest first", context do
      assert {:ok, %{@nothing | due_count: 2, fetched_count: 2}} == run(context)
      assert requested_types() == [@v3_vehicle_types, @v2_vehicle_types]
    end

    test "holds the types of each version under its own identifier", context do
      {:ok, _counts} = run(context)

      assert type_ids(context, "3.0") == ["10", "3", "4", "6", "7", "8", "9"]
      assert type_ids(context, "2.2") == ["1", "2", "3", "4"]
    end

    test "fetches nothing for a system that serves 1.0 alone", context do
      system = %{@system | discovery_urls: Map.take(@system.discovery_urls, ["1.0"])}

      assert run(context, systems: [system]) == {:ok, @nothing}
      assert requested_types() == []
    end
  end

  describe "run/1 slots" do
    test "fetches nothing when each version has a fetch since its slot", context do
      seed(context, "3.0", slot_time("3.0", 0))
      seed(context, "2.2", slot_time("2.2", 1))

      assert run(context) == {:ok, @nothing}
      assert requested_types() == []
    end

    test "fetches a version whose fetch was made before its latest slot", context do
      seed(context, "3.0", slot_time("3.0", -1))
      seed(context, "2.2", slot_time("2.2", 0))

      assert {:ok, %{@nothing | due_count: 1, fetched_count: 1}} == run(context)
      assert requested_types() == [@v3_vehicle_types]
    end
  end

  describe "run/1 a version that publishes no types" do
    test "counts a vehicle_types file that answers 404 as not published", context do
      serve(Map.delete(@routes, @v2_vehicle_types))

      assert {:ok, %{@nothing | due_count: 2, fetched_count: 1, not_published_count: 1}} ==
               run(context)
    end

    test "does not fetch it again before its slot comes", context do
      serve(Map.delete(@routes, @v2_vehicle_types))
      {:ok, _counts} = run(context)
      _first = requested_types()

      assert run(context) == {:ok, @nothing}
      assert requested_types() == []
    end

    test "fetches it again once its slot has come", context do
      serve(Map.delete(@routes, @v2_vehicle_types))
      {:ok, _counts} = run(context)
      _first = requested_types()
      later = DateTime.add(@now, RouteSchedule.period_minutes(), :minute)

      assert {:ok, %{due_count: 2}} = run(context, clock: fn -> later end)
    end
  end

  describe "run/1 failures" do
    test "goes on to the next version when one fails", context do
      serve(Map.put(@routes, @v3_vehicle_types, {:status, 500}))

      assert {:ok, %{@nothing | due_count: 2, fetched_count: 1, failed_count: 1}} == run(context)
      assert type_ids(context, "2.2") == ["1", "2", "3", "4"]
    end

    test "fetches a failed version again at the next run", context do
      serve(Map.put(@routes, @v3_vehicle_types, {:status, 500}))
      {:ok, _counts} = run(context)
      serve(@routes)

      assert {:ok, %{@nothing | due_count: 1, fetched_count: 1}} == run(context)
    end

    test "returns an error when versions are due and none is fetched", context do
      serve(Map.new(@routes, fn {url, _response} -> {url, {:status, 503}} end))

      assert run(context) == {:error, :nothing_fetched}
    end

    test "counts a version the budget does not reach as skipped", context do
      assert {:ok, %{@nothing | due_count: 2, skipped_count: 2}} == run(context, budget_ms: 1)
      assert requested_types() == []
    end
  end

  describe "run/1 logging" do
    for {label, level, setup} <- [
          {"nothing due", :debug, :seeded},
          {"every version fetched", :info, :served},
          {"a version not published", :warning, :not_published},
          {"every version failed", :error, :failed}
        ] do
      test "logs once at #{level} for #{label}", context do
        case unquote(setup) do
          :seeded ->
            seed(context, "3.0", @now)
            seed(context, "2.2", @now)

          :served ->
            :ok

          :not_published ->
            serve(Map.delete(@routes, @v2_vehicle_types))

          :failed ->
            serve(Map.new(@routes, fn {url, _response} -> {url, {:status, 503}} end))
        end

        log =
          capture_log([level: :debug], fn ->
            run(context)
          end)

        lines =
          log
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ "GBFS vehicle types cycle"))

        assert [line] = lines
        assert line =~ "[#{unquote(level)}]"
      end
    end
  end
end
