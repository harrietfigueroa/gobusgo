defmodule Gobusgo.Gbfs.RawVehicleStatusTest do
  # Builds the stored form of fetches the test names and reads back what
  # their destinations name, with no process and no storage.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Gbfs.RawVehicleStatus

  @request_id "019a6a2e-7c3b-7d1e-8f00-0123456789ab"
  @body ~s({"version":"3.0"})
  @fetched_at ~U[2026-11-08 19:07:58.123456Z]

  defp build(overrides \\ %{}) do
    fetched = Map.merge(%{version: "3.0", body: @body, fetched_at: @fetched_at}, overrides)

    RawVehicleStatus.build(%{
      system_id: "lime_seattle",
      fetched: fetched,
      request_id: @request_id
    })
  end

  test "stores the body as received" do
    assert build().content == @body
  end

  test "names the system's partition of the fetch date, the time, the request, and the version" do
    assert build().destination ==
             "raw/gbfs/free-bike-status/dt=2026-11-08/system=lime_seattle/" <>
               "20261108T190758Z_#{@request_id}_v3.0_" <>
               binary_part(RawVehicleStatus.body_sha256(@body), 0, 12) <> ".json.gz"
  end

  for version <- ["3.0", "2.2", "1.0"] do
    test "reads back the #{version} it names" do
      stored = build(%{version: unquote(version)})

      assert {:ok, named} = RawVehicleStatus.parse_destination(stored.destination)
      assert %{system_id: "lime_seattle", version: unquote(version)} = named
      assert named.fetched_at == ~U[2026-11-08 19:07:58Z]
      assert named.request_id == @request_id
    end
  end

  test "accepts the content it was built from" do
    stored = build()
    {:ok, named} = RawVehicleStatus.parse_destination(stored.destination)

    assert RawVehicleStatus.check_content(named, stored.content) == :ok
  end

  test "refuses content of another hash" do
    {:ok, named} = RawVehicleStatus.parse_destination(build().destination)

    assert RawVehicleStatus.check_content(named, @body <> " ") == {:error, :hash_mismatch}
  end

  for destination <- [
        "raw/gbfs/free-bike-status/dt=2026-11-08/system=lime_seattle/other.json.gz",
        "raw/gbfs/free-bike-status/dt=2026-11-09/system=lime_seattle/20261108T190758Z_019a6a2e-7c3b-7d1e-8f00-0123456789ab_v3.0_0123456789ab.json.gz",
        "raw/gbfs/free-bike-status/dt=2026-11-08/system=Lime/20261108T190758Z_019a6a2e-7c3b-7d1e-8f00-0123456789ab_v3.0_0123456789ab.json.gz",
        "raw/gbfs/free-bike-status/dt=2026-11-08/system=lime_seattle/20261108T190758Z_019a6a2e-7c3b-7d1e-8f00-0123456789ab_v4.0_0123456789ab.json.gz",
        "raw/oba/dt=2026-11-08/system=lime_seattle/20261108T190758Z_019a6a2e-7c3b-7d1e-8f00-0123456789ab_v3.0_0123456789ab.json.gz"
      ] do
    test "names nothing at #{destination}" do
      assert RawVehicleStatus.parse_destination(unquote(destination)) == :error
    end
  end

  test "refuses an unknown version" do
    assert_raise AssertionError, fn -> build(%{version: "4.0"}) end
  end

  test "refuses a fetch time outside UTC" do
    fetched_at = %{@fetched_at | time_zone: "Etc/GMT+8", zone_abbr: "-08", utc_offset: -28_800}

    assert_raise AssertionError, fn -> build(%{fetched_at: fetched_at}) end
  end
end
