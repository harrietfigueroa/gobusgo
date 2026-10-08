defmodule Gobusgo.Usage.StateTest do
  # Verifies the rules of usage recording as pure functions of a state, the
  # holders that open and close connections, and the times they do so at.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Usage.State

  @connected_at ~U[2026-10-08 17:00:00Z]
  @connection %{
    page: "vehicle",
    reconnect: false,
    device_class: "desktop",
    browser_family: "firefox",
    viewport_width_bucket: nil,
    language: nil,
    referrer_host: nil
  }

  defp new(settings \\ %{}) do
    State.new(Map.merge(%{open_count_max: 4, closed_count_max: 4}, settings))
  end

  defp open(state, holder, now_ms \\ 0) do
    State.open(state, %{
      holder: holder,
      connection: @connection,
      connected_at: @connected_at,
      now_ms: now_ms
    })
  end

  defp opened(state, holder, now_ms \\ 0) do
    {state, :opened} = open(state, holder, now_ms)
    state
  end

  defp close(state, holder, now_ms), do: State.close(state, %{holder: holder, now_ms: now_ms})

  describe "new/1" do
    for settings <- [%{open_count_max: 0}, %{closed_count_max: 0}] do
      test "refuses #{inspect(settings)}" do
        assert_raise AssertionError, fn -> new(unquote(Macro.escape(settings))) end
      end
    end
  end

  describe "open/2" do
    test "opens a connection" do
      {state, outcome} = open(new(), :a)

      assert outcome == :opened
      assert State.open?(state, :a)
    end

    test "keeps the connection a holder has" do
      state = opened(new(), :a, 0)
      {state, outcome} = open(state, :a, 500)

      assert outcome == :already_open
      assert [%{"durationMs" => 1_000}] = state |> close(:a, 1_000) |> State.closed(1)
    end

    test "refuses a connection beyond the bound and counts it" do
      state = new(%{open_count_max: 1}) |> opened(:a)
      {state, outcome} = open(state, :b)

      assert outcome == :open_count_exceeded
      refute State.open?(state, :b)
      assert {%{open_count: 1, closed_count: 0}, _state} = State.take_dropped(state)
    end

    test "has room again once a connection closes" do
      state = new(%{open_count_max: 1}) |> opened(:a) |> close(:a, 1)

      assert {_state, :opened} = open(state, :b)
    end
  end

  describe "close/2" do
    test "leaves a record with the time the connection was open" do
      state = new() |> opened(:a, 1_000) |> close(:a, 61_000)

      assert [%{"durationMs" => 60_000, "page" => "vehicle", "connectedAt" => connected_at}] =
               State.closed(state, 1)

      assert connected_at == DateTime.to_iso8601(@connected_at)
      refute State.open?(state, :a)
    end

    test "leaves one record per connection, however often it is closed" do
      state = new() |> opened(:a) |> close(:a, 1) |> close(:a, 2)

      assert State.closed_count(state) == 1
    end

    test "changes nothing for a holder with no connection" do
      state = new()

      assert close(state, :a, 1) == state
    end

    test "leaves no record beyond the bound and counts the connection" do
      state =
        new(%{closed_count_max: 1})
        |> opened(:a)
        |> opened(:b)
        |> close(:a, 1)
        |> close(:b, 2)

      assert State.closed_count(state) == 1
      assert {%{open_count: 0, closed_count: 1}, _state} = State.take_dropped(state)
    end
  end

  describe "put_filter/2" do
    test "has the record hold the last filter the connection showed" do
      state =
        new()
        |> opened(:a)
        |> State.put_filter(%{holder: :a, filter: %{"agency" => ["1"]}})
        |> State.put_filter(%{holder: :a, filter: %{"agency" => ["40"]}})
        |> close(:a, 1)

      assert [%{"filter" => %{"agency" => ["40"]}}] = State.closed(state, 1)
    end

    test "leaves a record with no filter for a connection that showed none" do
      assert [%{"filter" => %{}}] = new() |> opened(:a) |> close(:a, 1) |> State.closed(1)
    end

    test "changes nothing for a holder with no connection" do
      state = new()

      assert State.put_filter(state, %{holder: :a, filter: %{"agency" => ["1"]}}) == state
    end
  end

  describe "closed/2 and drop_closed/2" do
    defp three_closed do
      new()
      |> opened(:a)
      |> opened(:b)
      |> opened(:c)
      |> close(:a, 10)
      |> close(:b, 20)
      |> close(:c, 30)
    end

    test "returns the records closed earliest first, up to the count" do
      assert [%{"durationMs" => 10}, %{"durationMs" => 20}] = State.closed(three_closed(), 2)
    end

    test "forgets the records closed earliest" do
      state = State.drop_closed(three_closed(), 2)

      assert State.closed_count(state) == 1
      assert [%{"durationMs" => 30}] = State.closed(state, 4)
    end

    test "refuses to forget more records than it holds" do
      assert_raise AssertionError, fn -> State.drop_closed(three_closed(), 4) end
    end
  end

  describe "take_dropped/1" do
    test "returns the counts once" do
      {state, :open_count_exceeded} = new(%{open_count_max: 1}) |> opened(:a) |> open(:b)
      {_dropped, state} = State.take_dropped(state)

      assert {%{open_count: 0, closed_count: 0}, _state} = State.take_dropped(state)
    end
  end
end
