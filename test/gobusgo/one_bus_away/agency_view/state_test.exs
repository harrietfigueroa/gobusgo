defmodule Gobusgo.OneBusAway.AgencyView.StateTest do
  # Verifies the view's rules as a pure function over decoded records written
  # out by hand: when a fetch is held, when it becomes current, and when a
  # record is ignored.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyView.State

  @first %{
    request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
    fetched_at: ~U[2026-10-02 03:15:00Z]
  }
  @second %{
    request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002",
    fetched_at: ~U[2026-10-02 03:16:00Z]
  }

  defp agency(id, fetch), do: {:agency, Map.put(fetch, :agency, %{"id" => id})}

  defp manifest(agency_ids, fetch) do
    {:manifest,
     Map.merge(fetch, %{agency_ids: agency_ids, data_sha256: "hash", destination: "raw/file"})}
  end

  defp put_all(state, records) do
    Enum.reduce(records, {state, []}, fn record, {state, outcomes} ->
      {state, outcome} = State.put(state, record)
      {state, outcomes ++ [outcome]}
    end)
  end

  defp current_ids(state) do
    case State.current(state) do
      nil -> nil
      %{agency_ids: agency_ids} -> agency_ids
    end
  end

  describe "current/1" do
    test "is nil before any fetch is complete" do
      assert State.current(State.new()) == nil
    end
  end

  describe "put/2 completing a fetch" do
    test "holds agency records until their manifest arrives" do
      {state, outcomes} = put_all(State.new(), [agency("1", @first), agency("40", @first)])

      assert outcomes == [:held, :held]
      assert State.current(state) == nil
    end

    test "switches to a fetch when its manifest arrives after its agencies" do
      {state, outcomes} =
        put_all(State.new(), [
          agency("40", @first),
          agency("1", @first),
          manifest(["1", "40"], @first)
        ])

      assert outcomes == [:held, :held, :switched]

      assert State.current(state) == %{
               request_id: @first.request_id,
               fetched_at: @first.fetched_at,
               agency_ids: ["1", "40"],
               agencies: %{"1" => %{"id" => "1"}, "40" => %{"id" => "40"}}
             }
    end

    test "holds a manifest that arrives first and switches on its last agency" do
      {state, outcomes} =
        put_all(State.new(), [
          manifest(["1", "40"], @first),
          agency("1", @first),
          agency("40", @first)
        ])

      assert outcomes == [:held, :held, :switched]
      assert current_ids(state) == ["1", "40"]
    end

    test "switches on the manifest alone for a fetch without agencies" do
      {state, outcome} = State.put(State.new(), manifest([], @first))

      assert outcome == :switched
      assert current_ids(state) == []
    end

    test "leaves an agency the manifest does not name out of the fetch" do
      {state, _outcomes} =
        put_all(State.new(), [agency("1", @first), agency("77", @first), manifest(["1"], @first)])

      assert Map.keys(State.current(state).agencies) == ["1"]
    end
  end

  describe "put/2 with a later fetch" do
    setup do
      {state, _outcomes} =
        put_all(State.new(), [
          agency("1", @first),
          agency("40", @first),
          manifest(["1", "40"], @first)
        ])

      %{state: state}
    end

    test "keeps the current fetch while the later one misses an agency", %{state: state} do
      {state, outcomes} = put_all(state, [agency("1", @second), manifest(["1", "40"], @second)])

      assert outcomes == [:held, :held]
      assert State.current(state).request_id == @first.request_id
    end

    test "drops an agency the later fetch no longer names", %{state: state} do
      {state, outcomes} = put_all(state, [agency("1", @second), manifest(["1"], @second)])

      assert outcomes == [:held, :switched]
      assert State.current(state).request_id == @second.request_id
      assert current_ids(state) == ["1"]
    end

    test "switches to a fetch with the same fetch time and another request", %{state: state} do
      same_time = %{@second | fetched_at: @first.fetched_at}

      {state, outcomes} = put_all(state, [agency("1", same_time), manifest(["1"], same_time)])

      assert outcomes == [:held, :switched]
      assert State.current(state).request_id == same_time.request_id
    end
  end

  describe "put/2 ignoring records" do
    setup do
      {state, _outcomes} = put_all(State.new(), [agency("1", @second), manifest(["1"], @second)])
      %{state: state}
    end

    test "ignores the records of a fetch older than the current one", %{state: state} do
      {after_state, outcomes} = put_all(state, [agency("40", @first), manifest(["40"], @first)])

      assert outcomes == [:ignored, :ignored]
      assert after_state == state
    end

    test "ignores the records of the current fetch published again", %{state: state} do
      {after_state, outcomes} = put_all(state, [agency("1", @second), manifest(["1"], @second)])

      assert outcomes == [:ignored, :ignored]
      assert after_state == state
    end

    test "ignores a record whose fetch time differs from the one its fetch is held under" do
      {state, :held} = State.put(State.new(), agency("1", @first))
      moved = %{@first | fetched_at: ~U[2026-10-02 03:15:30Z]}

      assert State.put(state, manifest(["1"], moved)) == {state, :ignored}
    end
  end

  describe "put/2 bounds" do
    test "forgets the oldest held fetch beyond the bound" do
      fetches =
        for index <- 0..State.held_fetch_count_max() do
          %{
            request_id:
              "0199c4a2-7e1b-7a3f-9d20-0000000001#{String.pad_leading("#{index}", 2, "0")}",
            fetched_at: DateTime.add(~U[2026-10-02 04:00:00Z], index, :minute)
          }
        end

      {state, _outcomes} = put_all(State.new(), Enum.map(fetches, &agency("1", &1)))
      oldest = hd(fetches)

      {state, outcome} = State.put(state, manifest(["1"], oldest))

      assert outcome == :held
      assert State.current(state) == nil
    end

    test "forgets held fetches older than the one it switches to" do
      {state, _outcomes} =
        put_all(State.new(), [agency("1", @first), agency("1", @second), manifest(["1"], @second)])

      assert State.put(state, manifest(["1"], @first)) == {state, :ignored}
    end
  end
end
