defmodule Gobusgo.PaceTest do
  # Starts a process per test with a clock the test moves, a path source that
  # serves one straight path, and the file backend under the test's temporary
  # directory; observes the reports of fetches and reads the files the
  # process writes back through the reader.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Pace
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Reader

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @origin_lon -122.34
  @origin_lat 47.6
  @service_date_ms 1_700_000_000_000
  @start_ms 1_700_000_000_000
  @prefix "paces/daily/"

  defmodule FlakyWriter do
    @moduledoc false
    @behaviour Gobusgo.Writer

    # Fails while the `:flaky` agent holds `:failing`, and stores through the
    # file backend otherwise.
    @impl Gobusgo.Writer
    def write(request, options) do
      case Agent.get(Keyword.fetch!(options, :flaky), & &1) do
        :failing -> {:error, :storage_full}
        :working -> Gobusgo.Writer.LocalFile.write(request, Keyword.delete(options, :flaky))
      end
    end
  end

  defp east_path do
    Learning.prepare_path(%{
      points: [[@origin_lon, @origin_lat], [@origin_lon + 0.01, @origin_lat]]
    })
  end

  defp serve_east_path(%{trip_id: "1_trip"}, _views), do: {:ok, east_path()}
  defp serve_east_path(%{trip_id: _other}, _views), do: :unavailable

  defp start(context, options \\ []) do
    # The clock starts first so it stops last: the process writes its table
    # as it shuts down and reads the clock then.
    clock = start_supervised!({Agent, fn -> ~U[2026-11-11 12:00:00Z] end})
    name = Module.concat(__MODULE__, "Pace#{System.unique_integer([:positive])}")

    options =
      Keyword.merge(
        [
          name: name,
          write_options: [base_dir: context.tmp_dir],
          path_source: &serve_east_path/2,
          node: "node1",
          clock: fn -> Agent.get(clock, & &1) end,
          check_interval_ms: 3_600_000
        ],
        options
      )

    start_supervised!({Pace, options})
    %{pace: name, clock: clock}
  end

  defp run_step(%{flaky: flaky}, {:writer, mode}), do: Agent.update(flaky, fn _ -> mode end)

  defp run_step(%{pace: pace}, {:pair, base_s}) do
    # Each pair starts where the vehicle was, since a vehicle does not go
    # back along its trip.
    start_m = 5 + div(base_s, 10)
    observe(pace, [vehicle(start_m, base_s)])
    observe(pace, [vehicle(start_m + 100, base_s + 10)])
  end

  defp run_step(%{pace: pace}, {:day, date}) do
    Agent.update(pace.clock, fn _ -> DateTime.new!(date, ~T[12:00:00], "Etc/UTC") end)
  end

  defp run_step(%{pace: pace}, :check) do
    send(Process.whereis(pace.pace), :check)
    _state = :sys.get_state(pace.pace)
    :ok
  end

  defp run_step(%{pace: pace}, :write), do: Pace.write(pace.pace)

  defp vehicle(meters, seconds, overrides \\ %{}) do
    meters_per_degree_lon = Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(@origin_lat))

    Map.merge(
      %{
        id: "v1",
        active_trip_id: "1_trip",
        route_id: "1_route",
        service_date_ms: @service_date_ms,
        last_known_location: %{
          lat: @origin_lat,
          lon: @origin_lon + meters / meters_per_degree_lon
        },
        last_location_update_time_ms: @start_ms + seconds * 1000
      },
      overrides
    )
  end

  # The cast is handled before the call that follows it, so the state read
  # sees the observation.
  defp observe(%{pace: pace}, vehicles) do
    :ok = Pace.observe(pace, %{agency_id: "1", vehicles: vehicles})
    _state = :sys.get_state(pace)
    :ok
  end

  defp files(%{tmp_dir: tmp_dir}) do
    {:ok, %{destinations: destinations, cursor: nil}} =
      Reader.discover(%{prefix: @prefix, limit: 100, order: :ascending, cursor: nil},
        base_dir: tmp_dir
      )

    for destination <- destinations do
      {:ok, content} = Reader.read(destination, base_dir: tmp_dir)
      {destination, JSON.decode!(content)}
    end
  end

  defp total(cells, index) do
    Enum.sum(for {_key, sums} <- cells, do: Enum.at(sums, index))
  end

  describe "a vehicle's two reports" do
    test "are written as the day's cells", context do
      pace = start(context)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])

      assert {:ok, cell_count} = Pace.write(pace.pace)
      assert cell_count > 0

      assert [{destination, %{"meta" => meta, "cells" => cells}}] = files(context)
      assert String.starts_with?(destination, "paces/daily/dt=2026-11-11/node1-")
      assert meta["date"] == "2026-11-11"
      assert meta["cellCount"] == cell_count
      assert_in_delta total(cells, 0), 10, 0.01
      assert_in_delta total(cells, 1), 100, 0.5
    end

    test "log one line per write with the date, cells, and meters", context do
      pace = start(context)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])

      log = capture_log(fn -> Pace.write(pace.pace) end)
      assert log =~ "Pace table written"
    end

    test "add nothing when the later one is the same report", context do
      pace = start(context)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])
      observe(pace, [vehicle(105, 10)])

      Pace.write(pace.pace)
      assert [{_destination, %{"cells" => cells}}] = files(context)
      assert_in_delta total(cells, 0), 10, 0.01
    end

    test "add nothing where the trip has no path", context do
      pace = start(context)
      observe(pace, [vehicle(5, 0, %{active_trip_id: "2_trip"})])
      observe(pace, [vehicle(105, 10, %{active_trip_id: "2_trip"})])

      assert Pace.write(pace.pace) == {:ok, 0}
      assert files(context) == []
    end
  end

  describe "the end of the UTC day" do
    test "writes the day's table on the next report and starts the next one with that report",
         context do
      pace = start(context)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])

      Agent.update(pace.clock, fn _ -> ~U[2026-11-12 00:00:05Z] end)
      observe(pace, [vehicle(205, 20)])

      assert [{destination, %{"meta" => %{"date" => "2026-11-11"}, "cells" => first_cells}}] =
               files(context)

      assert String.contains?(destination, "dt=2026-11-11")
      assert_in_delta total(first_cells, 0), 10, 0.01

      assert {:ok, _cell_count} = Pace.write(pace.pace)

      assert [_first, {_destination, %{"meta" => %{"date" => "2026-11-12"}, "cells" => cells}}] =
               files(context)

      assert_in_delta total(cells, 0), 10, 0.01
    end

    test "writes at the check when no report comes", context do
      pace = start(context, check_interval_ms: 10)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])
      Agent.update(pace.clock, fn _ -> ~U[2026-11-12 00:00:05Z] end)

      assert eventually(fn -> files(context) != [] end)
    end
  end

  describe "a table the writer did not store" do
    # Each scenario runs its steps against a writer a step switches between
    # failing and working, then reads the files written as `{date, seconds}`.
    # `{:pair, base_s}` observes one vehicle's two reports ten seconds apart
    # from `base_s`, `{:day, date}` moves the clock to noon of `date`, and
    # `:check` is the minute check.
    for {name, steps, expected_files, expected_log} <- [
          {"is retried by the next check and written under its own date",
           [
             {:writer, :failing},
             {:pair, 0},
             {:day, ~D[2026-11-12]},
             {:pair, 1000},
             {:writer, :working},
             :check
           ], [{~D[2026-11-11], 10.0}], nil},
          {"is not retried by an observation",
           [
             {:writer, :failing},
             {:pair, 0},
             {:day, ~D[2026-11-12]},
             {:pair, 1000},
             {:writer, :working},
             {:pair, 2000}
           ], [], nil},
          {"keeps the new day's reports out of the finished day's table",
           [
             {:writer, :failing},
             {:pair, 0},
             {:day, ~D[2026-11-12]},
             {:pair, 1000},
             {:pair, 2000},
             {:writer, :working},
             :check,
             :write
           ], [{~D[2026-11-11], 10.0}, {~D[2026-11-12], 20.0}], nil},
          {"is replaced, with a log of what was dropped, by a second one that fails to write",
           [
             {:writer, :failing},
             {:pair, 0},
             {:day, ~D[2026-11-12]},
             {:pair, 1000},
             {:day, ~D[2026-11-13]},
             {:pair, 2000},
             {:writer, :working},
             :check
           ], [{~D[2026-11-12], 10.0}], "Pace pending table dropped"}
        ] do
      test name, context do
        flaky = start_supervised!({Agent, fn -> :working end}, id: :flaky)

        pace =
          start(context,
            write_options: [backend: FlakyWriter, flaky: flaky, base_dir: context.tmp_dir]
          )

        log =
          capture_log(fn ->
            for step <- unquote(Macro.escape(steps)),
                do: run_step(%{pace: pace, flaky: flaky}, step)
          end)

        written =
          for {_destination, %{"meta" => %{"date" => date}, "cells" => cells}} <- files(context) do
            {Date.from_iso8601!(date), Float.round(total(cells, 0), 1)}
          end

        assert Enum.sort(written) == unquote(Macro.escape(expected_files))

        case unquote(expected_log) do
          nil -> refute log =~ "Pace pending table dropped"
          text -> assert log =~ text
        end
      end
    end
  end

  describe "the bounds" do
    test "keep at most the bound of cells and log it once", context do
      pace = start(context, cell_count_max: 1)

      log =
        capture_log(fn ->
          observe(pace, [vehicle(5, 0)])
          observe(pace, [vehicle(205, 20)])
          observe(pace, [vehicle(405, 40)])
        end)

      assert Pace.write(pace.pace) == {:ok, 1}
      assert [{_destination, %{"meta" => meta}}] = files(context)
      assert meta["droppedCellCount"] > 0
      assert length(String.split(log, "Pace table full")) == 2
    end

    test "skip a fetch while the message queue holds more than the bound", context do
      pace = start(context, message_queue_length_max: 1)
      :ok = :sys.suspend(pace.pace)

      # The suspended process handles no cast, so the queue holds one after
      # the first call and two after the second, and the third finds it over
      # the bound.
      for {meters, seconds} <- [{5, 0}, {105, 10}, {205, 20}] do
        :ok = Pace.observe(pace.pace, %{agency_id: "1", vehicles: [vehicle(meters, seconds)]})
      end

      :ok = :sys.resume(pace.pace)
      _state = :sys.get_state(pace.pace)

      assert {:ok, _cell_count} = Pace.write(pace.pace)
      assert [{_destination, %{"cells" => cells}}] = files(context)
      assert_in_delta total(cells, 0), 10, 0.01
    end

    test "read no more paths than the build bound in one call", context do
      pace = start(context, path_build_count_max: 0)
      observe(pace, [vehicle(5, 0)])
      observe(pace, [vehicle(105, 10)])

      assert Pace.write(pace.pace) == {:ok, 0}
    end
  end

  describe "a path source that raises" do
    test "drops the report and logs once, leaving the process running", context do
      pace = start(context, path_source: fn _trip, _views -> raise "boom" end)

      log =
        capture_log(fn ->
          observe(pace, [vehicle(5, 0), vehicle(5, 0, %{id: "v2"})])
        end)

      assert length(String.split(log, "Pace paths not read")) == 2
      assert Pace.write(pace.pace) == {:ok, 0}
    end
  end

  describe "observe/2" do
    test "returns :ok for a process that is not running" do
      assert Pace.observe(Gobusgo.PaceTest.NotRunning, %{
               agency_id: "1",
               vehicles: [vehicle(5, 0)]
             }) == :ok
    end
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(check, attempts - 1)
    end
  end
end
