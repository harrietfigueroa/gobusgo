defmodule Gobusgo.OneBusAway.TripPathsServedTest do
  # The counters are one node-wide value, so these cases run one at a time.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.TripPathsServed

  setup do
    TripPathsServed.init()
    :ok
  end

  test "flush returns the requests and trips recorded and sets them to zero" do
    :ok = TripPathsServed.record(3)
    :ok = TripPathsServed.record(40)

    assert TripPathsServed.flush() == %{request_count: 2, trip_count: 43}
    assert TripPathsServed.flush() == %{request_count: 0, trip_count: 0}
  end

  test "log writes one info line with the counts as properties" do
    :ok = TripPathsServed.record(7)

    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    output =
      capture_log([level: :info, metadata: :all], fn ->
        assert {:ok, %{trip_count: 7}} = TripPathsServed.log()
      end)

    assert output =~ "Trip paths requests served"
    assert output =~ "request_count=1"
    assert output =~ "trip_count=7"
  end

  test "the scheduler spec is an hourly fixed policy that passes the scheduler's checks" do
    spec = TripPathsServed.log_spec()

    assert spec.cadence.policy == {:fixed, 3_600_000}
  end

  test "a negative trip count is refused" do
    assert_raise FunctionClauseError, fn -> TripPathsServed.record(-1) end
  end
end
