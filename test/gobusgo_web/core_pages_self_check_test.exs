defmodule GobusgoWeb.CorePagesSelfCheckTest do
  # Checks that the core page check sees a core that renders differently:
  # the WebAssembly build aliases the core's trip_plan.js to a copy whose
  # walks read a minute longer, and the trip plan leaving at a time, whose
  # journey walks between two stops, must differ between the two builds.
  # The aliasing, the builds, and the reads are the same in every browser,
  # which the check itself runs in all three, so this runs in Chromium
  # alone.
  use PhoenixTest.Playwright.Case, async: false, browser_pool: :chromium

  alias Gobusgo.Test.CorePages
  alias Gobusgo.Test.CorePages.Scenarios

  @moduletag :core_pages
  @moduletag capture_log: true
  @moduletag timeout: 300_000

  @changed_trip_plan Path.expand("../support/core_pages/trip_plan_walk_longer.js", __DIR__)

  setup_all do
    changed =
      Path.relative_to(@changed_trip_plan, Path.expand("../../assets", __DIR__), force: true)

    Scenarios.prepare(%{
      builds: "self_check_builds",
      extra_aliases: %{webassembly: %{"#core/trip_plan.js" => changed}}
    })
  end

  test "a core whose walks read a minute longer renders a trip plan differently", context do
    pinned_at = DateTime.truncate(DateTime.utc_now(), :second)
    runs = Scenarios.runs(context, Scenarios.scenario(:trip_depart_at, pinned_at))
    [{:javascript, _conn, reference}, {:webassembly, _changed_conn, changed}] = runs

    assert "trip planner" in CorePages.differences(reference, changed)
  end
end
