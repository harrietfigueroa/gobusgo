defmodule GobusgoWeb.Mcp.Tools.ArrivalsTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, over the application's global views, hold
  # supervisor, and demand registry. The views are filled with
  # Gobusgo.Test.TransitSeeds and the registered demand is read back through
  # the registry's public reads. All of it is global state, hence the
  # non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.StopHolds
  alias GobusgoWeb.Mcp.Tools.Arrivals

  setup do
    TransitSeeds.restart_views()

    on_exit(fn ->
      Enum.each(StopHolds.held_stop_ids(), &StopHolds.release/1)
      TransitSeeds.restart_views()
    end)

    :ok = TransitSeeds.stops("1_100", [{"1_1", "Pine Street", nil}, {"1_2", "Union Street", nil}])
  end

  defp arrivals(stop_id) do
    {:ok, %{"structuredContent" => structured} = result} = Arrivals.call(%{"stopId" => stop_id})
    {result, structured}
  end

  defp open_stop_ids, do: Demand.items(Demand, DemandKey.arrivals_dataset())

  describe "a stop with a fetch" do
    test "answers the arrivals of its fetch, soonest first" do
      :ok = TransitSeeds.arrivals("1_1", [{"late", 20}, {"soon", 5}])

      {_result, %{"data" => data}} = arrivals("1_1")

      assert %{"status" => "arrivals", "stopId" => "1_1", "arrivals" => [soon, late]} = data
      assert %{"tripId" => "soon", "route" => "36", "headsign" => "Othello Station"} = soon
      assert %{"tripId" => "late", "predicted" => false} = late
    end

    test "answers what the page shows for the stop" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      {_result, %{"data" => %{"arrivals" => [arrival]}}} = arrivals("1_1")

      assert %{status: :arrivals, arrivals: [%{minutes: minutes, route: "36"}]} =
               GobusgoWeb.TransitQuery.stop_arrivals("1_1")

      assert arrival["minutes"] == minutes
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(arrival["time"])
    end

    test "names the fetch in meta" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      {_result, %{"meta" => meta}} = arrivals("1_1")

      assert %{"fetchedAt" => fetched_at, "requestId" => request_id, "count" => 1} = meta
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(fetched_at)
      assert is_binary(request_id)
    end

    test "carries the same answer as structured content and as text" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      {result, structured} = arrivals("1_1")

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "holds the stop so the arrival source keeps it fresh" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      arrivals("1_1")

      assert open_stop_ids() == ["1_1"]
    end

    test "holds at most the bound of arrivals" do
      trips = for number <- 1..30, do: {"trip-#{number}", number}
      :ok = TransitSeeds.arrivals("1_1", trips)

      {_result, %{"data" => %{"arrivals" => kept}}} = arrivals("1_1")

      assert length(kept) == GobusgoWeb.StopArrivals.arrival_count_max()
      assert length(kept) <= GobusgoWeb.Mcp.Answer.item_count_max()
    end

    test "gives the same answer to a call between fetches" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      {_first, first} = arrivals("1_1")
      {_second, second} = arrivals("1_1")

      assert first == second
    end

    test "gives a newer fetch's answer once it arrives" do
      :ok = TransitSeeds.arrivals("1_1", [{"old", 5}])
      {_before, _answer} = arrivals("1_1")

      :ok = TransitSeeds.arrivals("1_1", [{"new", 6}])

      {_after, %{"data" => %{"arrivals" => [%{"tripId" => trip_id}]}}} = arrivals("1_1")
      assert trip_id == "new"
    end

    test "answers a stop that a page has open from its fetch without holding it" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])
      page = start_page_holding("1_1")
      for number <- 1..StopHolds.hold_count_max(), do: hold_other_stop(number)

      {_result, %{"data" => %{"status" => status}}} = arrivals("1_1")

      assert status == "arrivals"
      assert StopHolds.held_stop_ids() |> Enum.member?("1_1") == false
      Process.exit(page, :kill)
    end
  end

  describe "a stop with no fetch" do
    test "answers fetching with the time to ask again, one request of the arrival source" do
      {_result, %{"data" => data, "meta" => meta}} = arrivals("1_1")

      assert data == %{
               "status" => "fetching",
               "stopId" => "1_1",
               "retryAfterSeconds" => div(Sources.arrival_interval_ms(), 1_000)
             }

      assert %{"fetchedAt" => nil, "requestId" => nil, "count" => 0} = meta
    end

    test "registers the stop in the demand registry as a page's open stop is" do
      arrivals("1_1")

      assert open_stop_ids() == ["1_1"]
    end

    test "answers its arrivals on the next call after the fetch arrives" do
      {_result, %{"data" => %{"status" => "fetching"}}} = arrivals("1_1")

      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert {_result,
              %{"data" => %{"status" => "arrivals", "arrivals" => [%{"tripId" => "soon"}]}}} =
               arrivals("1_1")
    end

    test "answers fetching again while the stop waits, holding it once" do
      arrivals("1_1")
      {_result, %{"data" => %{"status" => status}}} = arrivals("1_1")

      assert status == "fetching"
      assert Demand.holder_count(Demand, DemandKey.arrivals("1_1")) == 1
    end
  end

  describe "at the cap" do
    setup do
      for number <- 1..StopHolds.hold_count_max(), do: hold_other_stop(number)
      :ok
    end

    test "answers the cap outcome with the length of a hold to wait" do
      {_result, %{"data" => data}} = arrivals("1_1")

      assert data == %{
               "status" => "capacity_reached",
               "stopId" => "1_1",
               "retryAfterSeconds" => div(StopHolds.hold_ms(), 1_000)
             }
    end

    test "registers nothing for the stop" do
      arrivals("1_1")

      refute "1_1" in open_stop_ids()
      refute "1_1" in StopHolds.held_stop_ids()
    end

    test "still answers a stop the clients hold already" do
      :ok = StopHolds.release("other-1")
      :held = StopHolds.hold("1_1", %{hold_ms: StopHolds.hold_ms()})
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert {_result, %{"data" => %{"status" => "arrivals"}}} = arrivals("1_1")
    end

    test "answers again after a hold ends" do
      :ok = StopHolds.release("other-1")

      assert {_result, %{"data" => %{"status" => "fetching"}}} = arrivals("1_1")
    end
  end

  describe "a stop the stop view does not hold" do
    test "answers unknown_stop and registers nothing" do
      {_result, %{"data" => data}} = arrivals("1_404")

      assert data == %{"status" => "unknown_stop", "stopId" => "1_404"}
      assert open_stop_ids() == []
    end
  end

  describe "arguments_schema/0" do
    test "accepts a stop identifier" do
      assert Schema.mismatch(%{"stopId" => "1_1"}, Arrivals.arguments_schema()) == nil
    end

    test "refuses a call with no stop identifier" do
      assert %{path: ["stopId"], expected: :required} =
               Schema.mismatch(%{}, Arrivals.arguments_schema())
    end

    test "refuses a stop identifier that is not text" do
      assert %{path: ["stopId"]} = Schema.mismatch(%{"stopId" => 1}, Arrivals.arguments_schema())
    end
  end

  describe "call/1" do
    test "answers an error for an empty stop identifier and registers nothing" do
      assert {:error, text} = Arrivals.call(%{"stopId" => ""})

      assert text =~ "empty"
      assert open_stop_ids() == []
    end
  end

  describe "definition/0" do
    test "names the terms and credits the data as provided as is" do
      %{"description" => description} = Arrivals.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
    end
  end

  # Holds the stop `other-<number>` as a client of another stop would; the
  # stop view holds none of them, which the hold does not look at.
  defp hold_other_stop(number) do
    :held = StopHolds.hold("other-#{number}", %{hold_ms: StopHolds.hold_ms()})
  end

  # A process that registers the arrivals key of `stop_id` as a vehicle page
  # does, and holds it until the test kills it.
  defp start_page_holding(stop_id) do
    test_process = self()

    page =
      spawn(fn ->
        :ok = Demand.register(Demand, DemandKey.arrivals(stop_id))
        send(test_process, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    page
  end
end
