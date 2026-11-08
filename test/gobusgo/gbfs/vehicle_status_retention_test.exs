defmodule Gobusgo.Gbfs.VehicleStatusRetentionTest do
  # Stores vehicle files fetched at times the test names through the local
  # file writer under a temporary directory, runs the retention at a time
  # the test names, and reads which files the directory still holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.VehicleStatusRetention
  alias Gobusgo.Gbfs.VehicleTileSet
  alias Gobusgo.RequestId
  alias Gobusgo.Scheduler

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @now ~U[2026-11-08 00:05:00Z]
  @body ~s({"last_updated":"2026-11-08T00:00:00Z","ttl":60,"version":"3.0","data":{"vehicles":[]}})

  defp store(tmp_dir, fetched_at) do
    stored =
      RawVehicleStatus.build(%{
        system_id: "lime_seattle",
        fetched: %{version: "3.0", body: @body, fetched_at: fetched_at},
        request_id: RequestId.generate()
      })

    :ok =
      Gobusgo.Writer.write(%{destination: stored.destination, content: stored.content},
        base_dir: tmp_dir
      )

    stored.destination
  end

  defp run(tmp_dir, now \\ @now) do
    VehicleStatusRetention.run(
      now: fn -> now end,
      system_ids: ["lime_seattle"],
      read_options: [base_dir: tmp_dir],
      delete_options: [base_dir: tmp_dir]
    )
  end

  defp stored?(tmp_dir, destination) do
    match?({:ok, _content}, Gobusgo.Reader.read(destination, base_dir: tmp_dir))
  end

  defp ages_ms, do: [0, 60_000, 300_000, 509_000, 509_001, 600_000, 3_600_000, 2 * 86_400_000]

  test "leaves no stored file older than ten minutes", %{tmp_dir: tmp_dir} do
    destinations =
      for age_ms <- ages_ms(),
          do: {age_ms, store(tmp_dir, DateTime.add(@now, -age_ms, :millisecond))}

    {:ok, _counts} = run(tmp_dir)

    kept_ages_ms =
      for {age_ms, destination} <- destinations, stored?(tmp_dir, destination), do: age_ms

    assert Enum.all?(kept_ages_ms, &(&1 < VehicleStatusRetention.stored_age_ms_max()))
  end

  test "keeps the files fetched within the deletion age", %{tmp_dir: tmp_dir} do
    destinations =
      for age_ms <- [0, 60_000, 509_000],
          do: store(tmp_dir, DateTime.add(@now, -age_ms, :millisecond))

    assert {:ok, %{deleted_count: 0}} = run(tmp_dir)
    assert Enum.all?(destinations, &stored?(tmp_dir, &1))
  end

  # A file fetched the moment after a run is older than the deletion age at
  # the next run, which starts at most one interval, one evaluation period,
  # and one deadline later: it is gone before it is ten minutes old.
  test "deletes a file at the run after it passes the deletion age", %{tmp_dir: tmp_dir} do
    destination = store(tmp_dir, @now)
    age_ms = VehicleStatusRetention.deletion_age_ms() + 1

    {:ok, %{deleted_count: 1}} = run(tmp_dir, DateTime.add(@now, age_ms, :millisecond))

    refute stored?(tmp_dir, destination)
  end

  test "has a deletion age that leaves room for one run after it inside ten minutes" do
    gap_ms = 60_000 + 30_000 + Scheduler.evaluation_period_ms()

    assert VehicleStatusRetention.deletion_age_ms() + gap_ms <= 600_000
  end

  test "deletes the files of earlier days", %{tmp_dir: tmp_dir} do
    yesterday = store(tmp_dir, ~U[2026-11-07 23:50:00Z])
    two_days_ago = store(tmp_dir, ~U[2026-11-06 12:00:00Z])

    assert {:ok, %{deleted_count: 2}} = run(tmp_dir)
    refute stored?(tmp_dir, yesterday)
    refute stored?(tmp_dir, two_days_ago)
  end

  test "counts and keeps a name it does not recognize", %{tmp_dir: tmp_dir} do
    destination =
      RawVehicleStatus.partition_prefix("lime_seattle", ~D[2026-11-08]) <> "other.json"

    :ok = Gobusgo.Writer.write(%{destination: destination, content: "{}"}, base_dir: tmp_dir)

    assert {:ok, %{unrecognized_count: 1}} = run(tmp_dir)
    assert stored?(tmp_dir, destination)
  end

  describe "the files that publish a fetch" do
    defp publish(tmp_dir, fetched_at) do
      vehicle = %{
        id: "bike-1",
        position: %{lat: 47.6114, lon: -122.337},
        vehicle_type_id: nil,
        current_range_meters: nil,
        is_disabled: false,
        is_reserved: false,
        last_reported: nil
      }

      set =
        VehicleTileSet.build(%{
          fetched: %{
            kind: :fetched,
            id: "lime_seattle",
            version: "2.2",
            last_updated: fetched_at,
            ttl: 60,
            vehicles: [vehicle],
            data_sha256: String.duplicate("0", 64),
            destination: "raw/gbfs/free-bike-status/test",
            fetched_at: fetched_at,
            request_id: RequestId.generate()
          },
          type_fetches: []
        })

      for file <- [set.index | set.files] do
        :ok = Gobusgo.Writer.write(file, base_dir: tmp_dir)
        file.destination
      end
    end

    test "deletes every file of a fetch past the deletion age", %{tmp_dir: tmp_dir} do
      age_ms = VehicleStatusRetention.deletion_age_ms() + 1
      destinations = publish(tmp_dir, DateTime.add(@now, -age_ms, :millisecond))

      {:ok, %{deleted_count: deleted_count}} = run(tmp_dir)

      assert deleted_count == length(destinations)
      refute Enum.any?(destinations, &stored?(tmp_dir, &1))
    end

    test "keeps the files of a fetch within the deletion age", %{tmp_dir: tmp_dir} do
      destinations = publish(tmp_dir, DateTime.add(@now, -60_000, :millisecond))

      assert {:ok, %{deleted_count: 0}} = run(tmp_dir)
      assert Enum.all?(destinations, &stored?(tmp_dir, &1))
    end

    test "removes the directory of a fetch it empties", %{tmp_dir: tmp_dir} do
      [index | _files] = publish(tmp_dir, ~U[2026-11-07 23:50:00Z])

      {:ok, _counts} = run(tmp_dir)

      refute File.exists?(Path.join(tmp_dir, Path.dirname(index)))
    end
  end

  test "finds nothing to delete in an empty store", %{tmp_dir: tmp_dir} do
    assert {:ok, %{deleted_count: 0, failed_count: 0, backlog: false}} = run(tmp_dir)
  end

  test "runs every minute with a deadline under its interval" do
    spec = VehicleStatusRetention.spec([])

    assert spec.cadence.policy == {:fixed, 60_000}
    assert Scheduler.assert_spec(spec) == :ok
  end
end
