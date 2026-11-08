defmodule GobusgoWeb.RouteStopTilesTest do
  # Calls the pure functions that read an archive's build time from its
  # destination and judge its freshness against the renewal age, and starts
  # a process over an archive stored in a temporary directory to show that a
  # discovered archive is judged by the time its name holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Writer
  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.RouteStopTiles.Build

  @moduletag :tmp_dir

  @built_at ~U[2026-10-05 01:00:00.123456Z]
  @age_seconds 3_600

  describe "built_at/1" do
    for {name, built_at} <- [
          {"microseconds", ~U[2026-10-05 01:00:00.123456Z]},
          {"whole seconds", ~U[2026-10-05 01:00:00Z]},
          {"milliseconds", ~U[2026-10-05 01:00:00.123Z]}
        ] do
      test "reads the build time of a destination built at #{name}" do
        built_at = unquote(Macro.escape(built_at))
        destination = RouteStopTiles.destination(built_at)

        assert {:ok, read} = RouteStopTiles.built_at(destination)
        assert DateTime.compare(read, built_at) == :eq
      end
    end

    for destination <- [
          "tiles/route-stops/dt=2026-10-05/other.pmtiles",
          "tiles/route-stops/dt=2026-10-05/route-stops-20261305T010000000000Z.pmtiles",
          "tiles/route-stops/dt=2026-10-05/route-stops-20261005T010000Z.pmtiles"
        ] do
      test "refuses #{destination}" do
        assert RouteStopTiles.built_at(unquote(destination)) == :unrecognized
      end
    end
  end

  describe "freshness/1" do
    test "is :none with no destination" do
      assert RouteStopTiles.freshness(%{destination: nil, now: @built_at}) == :none
    end

    test "is current with its age while younger than the renewal age" do
      now = DateTime.add(@built_at, @age_seconds, :second)
      destination = RouteStopTiles.destination(@built_at)

      assert RouteStopTiles.freshness(%{destination: destination, now: now}) ==
               {:current, @age_seconds}
    end

    test "is stale with its age at the renewal age" do
      now = DateTime.add(@built_at, Build.renewal_age_seconds(), :second)
      destination = RouteStopTiles.destination(@built_at)

      assert RouteStopTiles.freshness(%{destination: destination, now: now}) ==
               {:stale, Build.renewal_age_seconds()}
    end

    test "is :unrecognized for a destination whose name holds no build time" do
      destination = "tiles/route-stops/dt=2026-10-05/other.pmtiles"

      assert RouteStopTiles.freshness(%{destination: destination, now: @built_at}) ==
               :unrecognized
    end
  end

  test "judges a discovered archive by the build time its name holds", %{tmp_dir: tmp_dir} do
    destination = RouteStopTiles.destination(@built_at)

    :ok =
      Writer.write(%{destination: destination, content: "archive"},
        backend: Gobusgo.Writer.LocalFile,
        base_dir: tmp_dir
      )

    server =
      start_supervised!(
        {RouteStopTiles,
         name: :discovered, read_options: [backend: Gobusgo.Reader.LocalFile, base_dir: tmp_dir]}
      )

    discovered = RouteStopTiles.current_destination(server)
    now = DateTime.add(@built_at, @age_seconds, :second)

    assert RouteStopTiles.built(server) == nil

    assert RouteStopTiles.freshness(%{destination: discovered, now: now}) ==
             {:current, @age_seconds}
  end
end
