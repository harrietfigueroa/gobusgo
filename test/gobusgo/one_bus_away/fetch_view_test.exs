defmodule Gobusgo.OneBusAway.FetchViewTest do
  # Starts a view per test over a records module defined here, whose values
  # are JSON written by hand, and observes the view through its readers and
  # its announcements. The decoding of real records is covered with the
  # datasets' records modules.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.FetchView

  defmodule Lines do
    def decode(value) do
      case JSON.decode(value) do
        {:ok, %{"dataset" => "lines", "id" => id, "requestId" => request_id} = line} ->
          {:ok, fetched_at, 0} = DateTime.from_iso8601(line["fetchedAt"])
          {:ok, %{id: id, request_id: request_id, fetched_at: fetched_at, name: line["name"]}}

        {:ok, %{"dataset" => _other}} ->
          {:error, :unsupported_type}

        {:ok, _other} ->
          {:error, :schema_mismatch}

        {:error, _reason} ->
          {:error, :invalid_json}
      end
    end
  end

  @first_request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @second_request_id "0199c4a2-7e1b-7a3f-9d20-000000000002"

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {FetchView, name: view, pubsub: Gobusgo.PubSub, records: Lines, id_count_max: 2}
    )

    %{view: view}
  end

  defp value(overrides \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          "dataset" => "lines",
          "id" => "40",
          "requestId" => @first_request_id,
          "fetchedAt" => "2026-10-05T01:00:00Z",
          "name" => "first"
        },
        overrides
      )
    )
  end

  describe "readers" do
    test "return nothing before a fetch arrives", %{view: view} do
      assert FetchView.current(view) == []
      assert FetchView.current_fetch(view, "40") == nil
      assert FetchView.fetch_times(view) == %{}
    end

    test "return nothing for a view that is not running" do
      assert FetchView.current(NoSuchView) == []
      assert FetchView.current_fetch(NoSuchView, "40") == nil
      assert FetchView.fetch_times(NoSuchView) == %{}
    end

    test "return the fetch of each identifier in identifier order", %{view: view} do
      :ok = FetchView.apply_records(view, [value(), value(%{"id" => "1", "name" => "other"})])

      assert [%{id: "1", name: "other"}, %{id: "40", name: "first"}] = FetchView.current(view)

      assert FetchView.current_fetch(view, "40") == %{
               id: "40",
               request_id: @first_request_id,
               fetched_at: ~U[2026-10-05 01:00:00Z],
               name: "first"
             }
    end

    test "return the fetch time of each identifier", %{view: view} do
      :ok =
        FetchView.apply_records(view, [
          value(),
          value(%{"id" => "1", "fetchedAt" => "2026-10-05T03:00:00Z"})
        ])

      assert FetchView.fetch_times(view) == %{
               "40" => ~U[2026-10-05 01:00:00Z],
               "1" => ~U[2026-10-05 03:00:00Z]
             }
    end
  end

  describe "apply_records/2" do
    test "replaces a fetch with a newer one of the same identifier", %{view: view} do
      newer =
        value(%{
          "requestId" => @second_request_id,
          "fetchedAt" => "2026-10-05T02:00:00Z",
          "name" => "second"
        })

      :ok = FetchView.apply_records(view, [value()])
      :ok = FetchView.apply_records(view, [newer])

      assert %{name: "second"} = FetchView.current_fetch(view, "40")
    end

    test "keeps the current fetch when an older one arrives", %{view: view} do
      older = value(%{"requestId" => @second_request_id, "fetchedAt" => "2026-10-04T01:00:00Z"})

      :ok = FetchView.apply_records(view, [value(), older])

      assert %{request_id: @first_request_id} = FetchView.current_fetch(view, "40")
    end

    test "leaves out the fetch of an identifier beyond the bound", %{view: view} do
      values = for id <- ["1", "2", "3"], do: value(%{"id" => id})

      :ok = FetchView.apply_records(view, values)

      assert Enum.map(FetchView.current(view), & &1.id) == ["1", "2"]
    end

    test "passes over a record of another dataset without a log line", %{view: view} do
      log =
        capture_log(fn ->
          :ok = FetchView.apply_records(view, [value(%{"dataset" => "stops"}), value()])
        end)

      refute log =~ "Fetch view skipped invalid records"
      assert [%{id: "40"}] = FetchView.current(view)
    end

    test "skips a value that is not a record and logs the count once", %{view: view} do
      log =
        capture_log(fn ->
          :ok = FetchView.apply_records(view, ["{", JSON.encode!(%{"other" => 1}), value()])
        end)

      assert log =~ "Fetch view skipped invalid records"
      assert [%{id: "40"}] = FetchView.current(view)
    end

    test "raises for more values than a publisher call holds", %{view: view} do
      values = List.duplicate(value(), Gobusgo.Publisher.record_count_max() + 1)

      assert_raise AssertionError, ~r/at most/, fn -> FetchView.apply_records(view, values) end
    end
  end

  describe "apply_records_to_each/2" do
    test "hands the values to every view", %{view: view} = context do
      other = Module.concat(__MODULE__, "Other#{context.line}")

      start_supervised!(
        {FetchView, name: other, pubsub: Gobusgo.PubSub, records: Lines, id_count_max: 2}
      )

      :ok = FetchView.apply_records_to_each([view, other], [value()])

      assert [%{id: "40"}] = FetchView.current(view)
      assert [%{id: "40"}] = FetchView.current(other)
    end
  end

  describe "announcements" do
    setup %{view: view} do
      :ok = FetchView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
    end

    test "one arrives for a call that switches several identifiers", %{view: view} do
      :ok = FetchView.apply_records(view, [value(), value(%{"id" => "1"})])

      assert_received {:fetch_view_switched, ^view}
      refute_received {:fetch_view_switched, ^view}
    end

    test "arrives after the table holds the new fetch", %{view: view} do
      :ok = FetchView.apply_records(view, [value()])

      assert_received {:fetch_view_switched, ^view}
      assert %{id: "40"} = FetchView.current_fetch(view, "40")
    end

    test "none arrives for a call that switches nothing", %{view: view} do
      :ok = FetchView.apply_records(view, [value()])
      assert_received {:fetch_view_switched, ^view}

      :ok = FetchView.apply_records(view, [value(), value(%{"dataset" => "stops"})])

      refute_received {:fetch_view_switched, ^view}
    end
  end

  describe "a view whose fetches expire" do
    # The view reads the time from an agent the test sets, so a fetch ages
    # without the test waiting.
    setup context do
      clock = start_supervised!({Agent, fn -> ~U[2026-10-05 01:00:30Z] end})
      view = Module.concat(__MODULE__, "ExpiringView#{context.line}")

      start_supervised!(
        {FetchView,
         name: view,
         pubsub: Gobusgo.PubSub,
         records: Lines,
         id_count_max: 2,
         fetch_age_ms_max: 60_000,
         clock: fn -> Agent.get(clock, & &1) end},
        id: view
      )

      %{view: view, clock: clock}
    end

    test "drops a fetch older than the bound at the next call and announces it",
         %{view: view, clock: clock} do
      :ok = FetchView.apply_records(view, [value()])
      :ok = FetchView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
      Agent.update(clock, fn _time -> ~U[2026-10-05 01:01:01Z] end)

      :ok = FetchView.apply_records(view, [])

      assert FetchView.current(view) == []
      assert FetchView.fetch_times(view) == %{}
      assert_receive {:fetch_view_switched, ^view}
    end

    test "keeps a fetch the bound has not reached", %{view: view, clock: clock} do
      :ok = FetchView.apply_records(view, [value()])
      Agent.update(clock, fn _time -> ~U[2026-10-05 01:01:00Z] end)

      :ok = FetchView.apply_records(view, [])

      assert [%{id: "40"}] = FetchView.current(view)
    end

    test "ignores the record of a fetch older than the bound", %{view: view, clock: clock} do
      Agent.update(clock, fn _time -> ~U[2026-10-05 02:00:00Z] end)

      :ok = FetchView.apply_records(view, [value()])

      assert FetchView.current(view) == []
    end
  end
end
