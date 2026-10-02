defmodule Gobusgo.OneBusAway.AgencyViewTest do
  # Starts a view of its own per test and feeds it the record values
  # AgencyBatch.Records builds, the bytes the processor publishes, then reads
  # the view back the way a request does. Announcements travel over the
  # application's publish-subscribe server, on a topic of the test's own view.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.AgencyBatch.Records
  alias Gobusgo.OneBusAway.AgencyView

  @moduletag capture_log: true

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({AgencyView, name: view, pubsub: Gobusgo.PubSub})
    %{view: view}
  end

  defp agency(id) do
    %{
      id: id,
      name: "Agency #{id}",
      url: "https://#{id}.example.test",
      timezone: "America/Los_Angeles",
      coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
    }
  end

  defp records(ids, overrides \\ %{}) do
    Records.build(
      Map.merge(
        %{
          destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
          fetched_at: ~U[2026-10-02 03:15:00Z],
          data_sha256: String.duplicate("ab", 32),
          request_id: @request_id,
          agencies: Enum.map(ids, &agency/1)
        },
        overrides
      )
    )
  end

  defp values(%{agencies: agencies, manifest: manifest}) do
    Enum.map(agencies ++ [manifest], & &1.value)
  end

  describe "current/1" do
    test "is nil before a fetch is complete", %{view: view} do
      assert AgencyView.current(view) == nil
    end

    test "is nil for a view that is not running" do
      assert AgencyView.current(Gobusgo.OneBusAway.AgencyViewTest.NotStarted) == nil
    end

    test "is the fetch whose agencies and manifest were applied", %{view: view} do
      assert AgencyView.apply_records(view, values(records(["40", "1"]))) == :ok

      assert %{
               request_id: @request_id,
               fetched_at: ~U[2026-10-02 03:15:00Z],
               agency_ids: ["1", "40"],
               agencies: %{"1" => %{"name" => "Agency 1"}, "40" => %{"name" => "Agency 40"}}
             } = AgencyView.current(view)
    end
  end

  describe "apply_records/2" do
    test "keeps a fetch invisible until its manifest is applied", %{view: view} do
      %{agencies: agencies, manifest: manifest} = records(["1", "40"])

      assert AgencyView.apply_records(view, Enum.map(agencies, & &1.value)) == :ok
      assert AgencyView.current(view) == nil

      assert AgencyView.apply_records(view, [manifest.value]) == :ok
      assert AgencyView.current(view).agency_ids == ["1", "40"]
    end

    test "keeps the current fetch when an older one is applied", %{view: view} do
      :ok = AgencyView.apply_records(view, values(records(["1", "40"])))

      older =
        records(["1"], %{
          fetched_at: ~U[2026-10-02 03:14:00Z],
          request_id: "0199c4a2-7e1b-7a3f-9d20-000000000000"
        })

      assert AgencyView.apply_records(view, values(older)) == :ok
      assert AgencyView.current(view).request_id == @request_id
    end

    test "skips a value that is not a record and applies the rest", %{view: view} do
      assert AgencyView.apply_records(view, ["{not json" | values(records(["1"]))]) == :ok
      assert AgencyView.current(view).agency_ids == ["1"]
    end

    test "logs a switch once at info", %{view: view} do
      log =
        capture_log([metadata: :all], fn ->
          AgencyView.apply_records(view, values(records(["1", "40"])))
        end)

      assert log =~ "[info]"
      assert log =~ "Agency view switched"
      assert log =~ "request_id=#{@request_id}"
      assert log =~ "agency_count=2"
    end

    test "logs skipped values once at warning with their count", %{view: view} do
      log =
        capture_log([metadata: :all], fn ->
          AgencyView.apply_records(view, ["{not json", "{}"])
        end)

      assert log =~ "[warning]"
      assert log =~ "Agency view skipped invalid records"
      assert log =~ "invalid_count=2"
    end
  end

  describe "subscribe/1" do
    test "delivers one announcement when the current fetch changes", %{view: view} do
      assert AgencyView.subscribe(%{view: view, pubsub: Gobusgo.PubSub}) == :ok

      :ok = AgencyView.apply_records(view, values(records(["1", "40"])))

      assert_received {:agency_view_switched, ^view}
      refute_received {:agency_view_switched, ^view}
    end

    test "delivers nothing while a fetch is held", %{view: view} do
      :ok = AgencyView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
      %{agencies: agencies} = records(["1", "40"])

      :ok = AgencyView.apply_records(view, Enum.map(agencies, & &1.value))

      refute_received {:agency_view_switched, _view}
    end

    test "delivers nothing for the current fetch applied again", %{view: view} do
      :ok = AgencyView.apply_records(view, values(records(["1"])))
      :ok = AgencyView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})

      :ok = AgencyView.apply_records(view, values(records(["1"])))

      refute_received {:agency_view_switched, _view}
    end
  end
end
