defmodule Gobusgo.Pace.SeedTest do
  # Stores vehicle fetches under the test's temporary directory as ingestion
  # does, seeds a day from them with a path source that serves one straight
  # path, and reads the stored file back through the reader. Parity feeds the
  # same fetches to the ingestion process and compares the files.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.Pace
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Seed
  alias Gobusgo.Reader
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture Path.expand("../../fixtures/one_bus_away/vehicles_for_agency.json", __DIR__)
  @origin_lon -122.34
  @origin_lat 47.6
  @date ~D[2026-11-11]
  @day_start_ms 1_793_000_000_000
  @prefix "paces/daily/dt=2026-11-11/"
  @trip_id "40_1655020"

  defp east_path do
    Learning.prepare_path(%{
      points: [[@origin_lon, @origin_lat], [@origin_lon + 0.01, @origin_lat]]
    })
  end

  defp serve_east_path(%{trip_id: @trip_id}, _views), do: {:ok, east_path()}
  defp serve_east_path(%{trip_id: _other}, _views), do: :unavailable

  defp no_views(_date), do: :ok

  defp seed(context, overrides \\ []) do
    options =
      Keyword.merge(
        [
          date: @date,
          read_options: [base_dir: context.tmp_dir],
          write_options: [base_dir: context.tmp_dir],
          path_source: &serve_east_path/2,
          prepare_views: &no_views/1
        ],
        overrides
      )

    Seed.run(options)
  end

  # Stores the fetch of one vehicle, at `meters` east of the path's start as
  # of `seconds` into the day, as the response of `agency_id`.
  defp store_fetch(context, %{agency_id: agency_id, meters: meters, seconds: seconds} = fetch) do
    meters_per_degree_lon = Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(@origin_lat))
    reported_ms = @day_start_ms + seconds * 1000
    vehicle_id = Map.get(fetch, :vehicle_id, "40_41605")
    envelope = @fixture |> File.read!() |> JSON.decode!()

    vehicle =
      envelope["data"]["list"]
      |> hd()
      |> Map.merge(%{
        "vehicleId" => vehicle_id,
        "lastLocationUpdateTime" => reported_ms,
        "location" => %{
          "lat" => @origin_lat,
          "lon" => @origin_lon + meters / meters_per_degree_lon
        }
      })
      |> put_in(["tripStatus", "vehicleId"], vehicle_id)

    envelope = put_in(envelope, ["data", "list"], [vehicle])

    stored =
      RawVehicleResponse.build(%{
        response: %{
          agency_id: agency_id,
          vehicles: [],
          envelope: envelope,
          fetched_at: DateTime.add(~U[2026-11-11 00:00:00Z], seconds, :second),
          host: "oba.example.test",
          http_status: 200,
          method: "GET"
        },
        request_id: RequestId.generate()
      })

    :ok =
      Writer.write(%{destination: stored.destination, content: stored.content},
        base_dir: context.tmp_dir
      )

    stored.destination
  end

  defp store_chain(context, agency_id, options \\ []) do
    vehicle = Keyword.take(options, [:vehicle_id])

    for {meters, seconds} <- [{5, 0}, {105, 10}, {205, 20}] do
      store_fetch(
        context,
        Map.merge(%{agency_id: agency_id, meters: meters, seconds: seconds}, Map.new(vehicle))
      )
    end
  end

  defp files(base_dir, prefix \\ @prefix) do
    request = %{prefix: prefix, limit: 100, order: :ascending, cursor: nil}

    case Reader.discover(request, base_dir: base_dir) do
      {:ok, %{destinations: destinations}} ->
        for destination <- destinations do
          {:ok, content} = Reader.read(destination, base_dir: base_dir)
          {destination, JSON.decode!(content)}
        end

      {:error, :not_found} ->
        []
    end
  end

  defp total(cells, index), do: Enum.sum(for {_key, sums} <- cells, do: Enum.at(sums, index))

  describe "a day of stored fetches" do
    test "is written as one file of the seed node", context do
      store_chain(context, "40")

      assert {:written, summary} = seed(context)
      assert summary.fetch_count == 3
      assert summary.failed_fetch_count == 0

      assert [{destination, %{"meta" => meta, "cells" => cells}}] = files(context.tmp_dir)
      assert String.starts_with?(destination, "paces/daily/dt=2026-11-11/seed-")
      assert meta["node"] == "seed"
      assert meta["date"] == "2026-11-11"
      assert meta["cellCount"] == summary.cell_count
      assert_in_delta total(cells, 0), 20, 0.01
      assert_in_delta total(cells, 1), 200, 1
    end

    test "logs the date, the cells, the meters, and the fetches read", context do
      store_chain(context, "40")

      log = capture_log(fn -> seed(context) end)

      assert log =~ "Pace table seeded"
    end

    test "is named by the node it is given", context do
      store_chain(context, "40")
      seed(context, node: "backfill")

      assert [{destination, _file}] = files(context.tmp_dir)
      assert String.starts_with?(destination, "paces/daily/dt=2026-11-11/backfill-")
    end

    test "writes no file where no trip has a path", context do
      store_chain(context, "40")

      assert {:empty, %{cell_count: 0, fetch_count: 3}} =
               seed(context, path_source: fn _trip, _views -> :unavailable end)

      assert files(context.tmp_dir) == []
    end

    test "counts a fetch that cannot be read and learns from the rest", context do
      [_first | _rest] = store_chain(context, "40")

      File.write!(
        Path.join(
          context.tmp_dir,
          "raw/oba/vehicles-for-agency/dt=2026-11-11/agency=40/0_bad.json"
        ),
        "{"
      )

      assert {:written, %{fetch_count: 3, failed_fetch_count: 1}} = seed(context)
    end

    test "never chains a vehicle across agencies", context do
      store_fetch(context, %{agency_id: "40", meters: 5, seconds: 0})
      store_fetch(context, %{agency_id: "41", meters: 105, seconds: 10})

      assert {:empty, %{fetch_count: 2}} = seed(context)
    end

    test "reads the fetches of the date and no other", context do
      store_chain(context, "40")
      seed(context, date: ~D[2026-11-12])

      assert files(context.tmp_dir) == []
    end
  end

  describe "a date that has a file" do
    test "is skipped and the file is left as it was", context do
      store_chain(context, "40")
      assert {:written, _summary} = seed(context)
      [{_destination, before_file}] = files(context.tmp_dir)

      assert seed(context) == {:skipped, :already_written}
      assert [{_destination, ^before_file}] = files(context.tmp_dir)
    end

    test "is skipped when the file is the ingestion's", context do
      Writer.write(
        %{destination: "paces/daily/dt=2026-11-11/node1-x.json.gz", content: "{}"},
        base_dir: context.tmp_dir
      )

      store_chain(context, "40")

      assert seed(context) == {:skipped, :already_written}
      assert [{"paces/daily/dt=2026-11-11/node1-x.json.gz", _file}] = files(context.tmp_dir)
    end

    test "does not prepare the views", context do
      Writer.write(
        %{destination: "paces/daily/dt=2026-11-11/node1-x.json.gz", content: "{}"},
        base_dir: context.tmp_dir
      )

      prepare_views = fn _date -> flunk("the views are prepared for a skipped date") end
      assert seed(context, prepare_views: prepare_views) == {:skipped, :already_written}
    end
  end

  describe "the same fetches learned by the ingestion process" do
    test "give the same cells", context do
      destinations = store_chain(context, "40") ++ store_chain(context, "41", vehicle_id: "40_2")
      out_dir = Path.join(context.tmp_dir, "ingested")
      File.mkdir_p!(out_dir)

      assert {:written, _summary} = seed(context)

      name = Module.concat(__MODULE__, "Pace#{System.unique_integer([:positive])}")

      start_supervised!(
        {Pace,
         name: name,
         write_options: [base_dir: out_dir],
         path_source: &serve_east_path/2,
         node: "node1",
         clock: fn -> ~U[2026-11-11 12:00:00Z] end,
         check_interval_ms: 3_600_000}
      )

      for destination <- destinations do
        {:ok, content} = Reader.read(destination, base_dir: context.tmp_dir)
        {:ok, fetch} = RawVehicleResponse.parse(%{destination: destination, content: content})
        :ok = Pace.observe(name, fetch)
        _state = :sys.get_state(name)
      end

      assert {:ok, _cell_count} = Pace.write(name)

      [{_seeded, %{"cells" => seeded}}] = files(context.tmp_dir)
      [{_ingested, %{"cells" => ingested}}] = files(out_dir)
      assert map_size(seeded) > 0
      assert seeded == ingested
    end
  end

  describe "dates/1" do
    test "lists each day of a range, both ends included" do
      assert Seed.dates(%{from: ~D[2026-11-10], to: ~D[2026-11-12]}) ==
               {:ok, [~D[2026-11-10], ~D[2026-11-11], ~D[2026-11-12]]}
    end

    test "lists one day for one date" do
      assert Seed.dates(%{from: @date, to: @date}) == {:ok, [@date]}
    end

    test "refuses a range that runs backward" do
      assert Seed.dates(%{from: ~D[2026-11-12], to: ~D[2026-11-11]}) == {:error, :range_reversed}
    end

    test "refuses a range of more than 31 days" do
      assert Seed.dates(%{from: ~D[2026-10-01], to: ~D[2026-11-01]}) == {:error, :range_too_long}
      assert {:ok, dates} = Seed.dates(%{from: ~D[2026-10-01], to: ~D[2026-10-31]})
      assert length(dates) == 31
    end
  end
end
