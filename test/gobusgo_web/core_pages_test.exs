defmodule GobusgoWeb.CorePagesTest do
  # Checks that the WebAssembly core renders the pages a rider sees as the
  # JavaScript core does: each scenario of Gobusgo.Test.CorePages.Scenarios
  # runs in Chromium, Firefox, and WebKit, once on a build of the page's
  # bundles on each core served by the test server, with the browser's
  # clock pinned and the network of Gobusgo.Test.CorePages.Network as the
  # data, and fails on any region whose accessibility snapshot, rendered
  # text, map source data, or model context differs between the two,
  # naming the browser, the scenario, and the region and keeping both
  # sessions' Playwright traces.
  use PhoenixTest.Playwright.Case,
    async: false,
    parameterize: for(browser <- [:chromium, :firefox, :webkit], do: %{browser_pool: browser})

  alias Gobusgo.Test.CorePages.Scenarios

  @moduletag :core_pages
  @moduletag capture_log: true
  @moduletag timeout: 300_000

  setup_all do
    Scenarios.prepare(%{builds: "builds", extra_aliases: %{}})
  end

  for {scenario, title} <- [
        trip_depart_at: "a trip plan leaving at a time",
        trip_arrive_by: "a trip plan arriving by a time",
        board_for_time: "an arrivals board for a time",
        mcp_board: "an MCP arrivals board",
        offline: "the scheduled markers and a stop's arrivals offline"
      ] do
    test "#{title} renders the same on both cores", context do
      pinned_at = DateTime.truncate(DateTime.utc_now(), :second)
      Scenarios.compare(context, Scenarios.scenario(unquote(scenario), pinned_at))
    end
  end
end
