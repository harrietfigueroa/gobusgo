defmodule Gobusgo.OneBusAway.VehicleView.StateTest do
  # Verifies the view's rules as a pure function over decoded records written
  # out by hand: when a fetch is held, when it becomes its agency's current
  # fetch, when a record is ignored, and that one agency's fetches leave
  # another agency's current fetch alone.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.VehicleView.State

  @first %{
    request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
    fetched_at: ~U[2026-10-02 03:15:00Z],
    agency_id: "1"
  }
  @second %{
    request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002",
    fetched_at: ~U[2026-10-02 03:16:00Z],
    agency_id: "1"
  }
  @other_agency %{
    request_id: "0199c4a2-7e1b-7a3f-9d20-000000000040",
    fetched_at: ~U[2026-10-02 03:14:00Z],
    agency_id: "40"
  }

  defp vehicle(id, fetch), do: {:vehicle, Map.put(fetch, :vehicle, %{"id" => id})}

  defp manifest(vehicle_ids, fetch) do
    {:manifest,
     Map.merge(fetch, %{vehicle_ids: vehicle_ids, data_sha256: "hash", destination: "raw/file"})}
  end

  defp put_all(state, records) do
    Enum.reduce(records, {state, []}, fn record, {state, outcomes} ->
      {state, outcome} = State.put(state, record)
      {state, outcomes ++ [outcome]}
    end)
  end

  defp current_ids(state, agency_id) do
    case State.current(state) do
      %{^agency_id => %{vehicle_ids: vehicle_ids}} -> vehicle_ids
      _no_fetch -> nil
    end
  end

  describe "current/1" do
    test "holds no agency before any fetch is complete" do
      assert State.current(State.new()) == %{}
    end
  end

  describe "put/2 completing a fetch" do
    test "holds vehicle records until their manifest arrives" do
      {state, outcomes} = put_all(State.new(), [vehicle("a", @first), vehicle("b", @first)])

      assert outcomes == [:held, :held]
      assert State.current(state) == %{}
    end

    test "switches the agency to a fetch when its manifest arrives after its vehicles" do
      {state, outcomes} =
        put_all(State.new(), [
          vehicle("b", @first),
          vehicle("a", @first),
          manifest(["a", "b"], @first)
        ])

      assert outcomes == [:held, :held, :switched]

      assert State.current(state) == %{
               "1" => %{
                 agency_id: "1",
                 request_id: @first.request_id,
                 fetched_at: @first.fetched_at,
                 vehicle_ids: ["a", "b"],
                 vehicles: %{"a" => %{"id" => "a"}, "b" => %{"id" => "b"}}
               }
             }
    end

    test "holds a manifest that arrives first and switches on its last vehicle" do
      {state, outcomes} =
        put_all(State.new(), [
          manifest(["a", "b"], @first),
          vehicle("a", @first),
          vehicle("b", @first)
        ])

      assert outcomes == [:held, :held, :switched]
      assert current_ids(state, "1") == ["a", "b"]
    end

    test "switches on the manifest alone for a fetch without vehicles" do
      {state, outcome} = State.put(State.new(), manifest([], @first))

      assert outcome == :switched
      assert current_ids(state, "1") == []
    end

    test "leaves a vehicle the manifest does not name out of the fetch" do
      {state, _outcomes} =
        put_all(State.new(), [vehicle("a", @first), vehicle("z", @first), manifest(["a"], @first)])

      assert Map.keys(State.current(state)["1"].vehicles) == ["a"]
    end
  end

  describe "put/2 with a later fetch of the same agency" do
    setup do
      {state, _outcomes} =
        put_all(State.new(), [
          vehicle("a", @first),
          vehicle("b", @first),
          manifest(["a", "b"], @first)
        ])

      %{state: state}
    end

    test "keeps the current fetch while the later one misses a vehicle", %{state: state} do
      {state, outcomes} = put_all(state, [vehicle("a", @second), manifest(["a", "b"], @second)])

      assert outcomes == [:held, :held]
      assert State.current(state)["1"].request_id == @first.request_id
    end

    test "drops a vehicle the later fetch no longer names", %{state: state} do
      {state, outcomes} = put_all(state, [vehicle("a", @second), manifest(["a"], @second)])

      assert outcomes == [:held, :switched]
      assert State.current(state)["1"].request_id == @second.request_id
      assert current_ids(state, "1") == ["a"]
    end

    test "switches to a fetch with the same fetch time and another request", %{state: state} do
      same_time = %{@second | fetched_at: @first.fetched_at}

      {state, outcomes} = put_all(state, [vehicle("a", same_time), manifest(["a"], same_time)])

      assert outcomes == [:held, :switched]
      assert State.current(state)["1"].request_id == same_time.request_id
    end
  end

  describe "put/2 with fetches of two agencies" do
    setup do
      {state, _outcomes} = put_all(State.new(), [vehicle("a", @second), manifest(["a"], @second)])
      %{state: state}
    end

    test "switches another agency to a fetch older than this agency's", %{state: state} do
      {state, outcomes} =
        put_all(state, [vehicle("x", @other_agency), manifest(["x"], @other_agency)])

      assert outcomes == [:held, :switched]
      assert current_ids(state, "40") == ["x"]
    end

    test "keeps this agency's fetch when another agency switches", %{state: state} do
      {after_state, _outcomes} =
        put_all(state, [vehicle("x", @other_agency), manifest(["x"], @other_agency)])

      assert State.current(after_state)["1"] == State.current(state)["1"]
    end

    test "keeps another agency's held fetch when this agency switches" do
      later = %{@second | request_id: "0199c4a2-7e1b-7a3f-9d20-000000000003"}

      {state, outcomes} =
        put_all(State.new(), [
          vehicle("x", @other_agency),
          vehicle("a", later),
          manifest(["a"], later),
          manifest(["x"], @other_agency)
        ])

      assert outcomes == [:held, :held, :switched, :switched]
      assert current_ids(state, "40") == ["x"]
    end
  end

  describe "put/2 ignoring records" do
    setup do
      {state, _outcomes} = put_all(State.new(), [vehicle("a", @second), manifest(["a"], @second)])
      %{state: state}
    end

    test "ignores the records of a fetch older than the agency's current one", %{state: state} do
      {after_state, outcomes} = put_all(state, [vehicle("b", @first), manifest(["b"], @first)])

      assert outcomes == [:ignored, :ignored]
      assert after_state == state
    end

    test "ignores the records of the current fetch published again", %{state: state} do
      {after_state, outcomes} = put_all(state, [vehicle("a", @second), manifest(["a"], @second)])

      assert outcomes == [:ignored, :ignored]
      assert after_state == state
    end

    test "ignores a record whose fetch time differs from the one its fetch is held under" do
      {state, :held} = State.put(State.new(), vehicle("a", @first))
      moved = %{@first | fetched_at: ~U[2026-10-02 03:15:30Z]}

      assert State.put(state, manifest(["a"], moved)) == {state, :ignored}
    end

    test "ignores a record whose agency differs from the one its fetch is held under" do
      {state, :held} = State.put(State.new(), vehicle("a", @first))
      moved = %{@first | agency_id: "40"}

      assert State.put(state, manifest(["a"], moved)) == {state, :ignored}
    end
  end

  describe "put/2 bounds" do
    test "forgets the oldest held fetch beyond the bound" do
      fetches =
        for index <- 0..State.held_fetch_count_max() do
          %{
            request_id:
              "0199c4a2-7e1b-7a3f-9d20-0000000001#{String.pad_leading("#{index}", 2, "0")}",
            fetched_at: DateTime.add(~U[2026-10-02 04:00:00Z], index, :minute),
            agency_id: "1"
          }
        end

      {state, _outcomes} = put_all(State.new(), Enum.map(fetches, &vehicle("a", &1)))
      oldest = hd(fetches)

      {state, outcome} = State.put(state, manifest(["a"], oldest))

      assert outcome == :held
      assert State.current(state) == %{}
    end

    test "forgets the agency's held fetches older than the one it switches to" do
      {state, _outcomes} =
        put_all(State.new(), [
          vehicle("a", @first),
          vehicle("a", @second),
          manifest(["a"], @second)
        ])

      assert State.put(state, manifest(["a"], @first)) == {state, :ignored}
    end

    test "ignores the fetch of an agency beyond the agency bound" do
      {state, _outcomes} =
        Enum.reduce(1..State.agency_count_max(), {State.new(), []}, fn index, {state, _} ->
          fetch = %{@first | agency_id: "agency-#{index}", request_id: request_id(index)}
          State.put(state, manifest([], fetch))
        end)

      beyond = %{@first | agency_id: "beyond", request_id: request_id(0)}

      assert State.put(state, manifest([], beyond)) == {state, :ignored}
    end
  end

  defp request_id(index) do
    "0199c4a2-7e1b-7a3f-9d20-0000000002#{String.pad_leading("#{index}", 2, "0")}"
  end
end
