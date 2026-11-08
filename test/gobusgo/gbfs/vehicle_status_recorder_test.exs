defmodule Gobusgo.Gbfs.VehicleStatusRecorderTest do
  # Runs the shared vehicle recorder through the in-process publisher wired
  # the way the application wires it: the "response stored" event goes to
  # the response consumer, which hands the stored file to the processor, and
  # the processor's record goes to a view started for the test. A Req.Test
  # stub serves Lime's recorded 3.0 files by address, and an address it
  # leaves out answers 404, as an absent version does on the live feed. The
  # local file backends store, read, and delete under a temporary directory.
  # What a fetch leads to is read from the view and the directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.RawVehicleStatus.StoredEvent
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusBatch
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusRecorder
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.OneBusAway.ResponseConsumer
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)
  @stub_name VehicleStatusRecorder
  @origin "https://data.lime.bike/api/partners/v3/gbfs/seattle"
  @discovery_url @origin <> "/gbfs.json"
  @vehicle_status_url @origin <> "/vehicle_status.json"
  @checked_at ~U[2026-11-08 19:30:00Z]

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # The system of the test reads 3.0 alone, so a 404 there is a feed that
  # is gone.
  defp system, do: %{Systems.lime_seattle() | discovery_urls: %{"3.0" => @discovery_url}}

  defp serve(routes) do
    Req.Test.stub(@stub_name, fn conn ->
      url = "https://" <> conn.host <> conn.request_path

      case Map.fetch(routes, url) do
        {:ok, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)

        :error ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)
  end

  defp serve_vehicles(vehicle_status_body) do
    serve(%{
      @discovery_url => fixture("lime_v3_gbfs"),
      @vehicle_status_url => vehicle_status_body
    })
  end

  defp empty_vehicle_status do
    document = JSON.decode!(fixture("lime_v3_vehicle_status"))
    JSON.encode!(put_in(document, ["data", "vehicles"], []))
  end

  setup %{tmp_dir: tmp_dir} = context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {VehicleStatusView, name: view, pubsub: Gobusgo.PubSub, system_count_max: 4}
    )

    state_subscribers = %{Records.topic() => {VehicleStatusView, :apply_records, [view]}}

    process_options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: state_subscribers]
    ]

    subscribers =
      Map.put(
        state_subscribers,
        StoredEvent.topic(),
        {ResponseConsumer, :consume,
         [%{event: StoredEvent, processor: VehicleStatusBatch}, process_options]}
      )

    options = [
      fetch_options: [plug: {Req.Test, @stub_name}],
      write_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: subscribers],
      retention_options: [read_options: [base_dir: tmp_dir], delete_options: [base_dir: tmp_dir]],
      now: fn -> @checked_at end
    ]

    %{view: view, options: options}
  end

  defp record(context), do: VehicleStatusRecorder.record(system(), context.options)

  defp stored_destinations(tmp_dir) do
    Path.join([tmp_dir, RawVehicleStatus.destination_prefix(), "**", "*.json.gz"])
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, tmp_dir))
  end

  describe "a fetched feed" do
    setup do
      serve_vehicles(fixture("lime_v3_vehicle_status"))
    end

    test "is recorded with the version that answered", context do
      assert {:ok, %{kind: :recorded, version: "3.0", vehicle_count: 2, event_published: true}} =
               record(context)
    end

    test "reaches the view with its vehicles and its version", context do
      {:ok, _recorded} = record(context)

      assert %{kind: :fetched, version: "3.0", vehicles: vehicles} =
               VehicleStatusView.current(context.view, "lime_seattle")

      assert Enum.map(vehicles, & &1.vehicle_type_id) == ["8", "3"]
    end

    test "is stored under the system's partition, compressed", %{tmp_dir: tmp_dir} = context do
      {:ok, %{destination: destination}} = record(context)

      assert stored_destinations(tmp_dir) == [destination]
      assert destination =~ ~r"^raw/gbfs/free-bike-status/dt=\d{4}-\d\d-\d\d/system=lime_seattle/"
      assert String.ends_with?(destination, ".json.gz")
    end

    test "is stored as the file the feed served", %{tmp_dir: tmp_dir} = context do
      {:ok, %{destination: destination}} = record(context)

      assert {:ok, content} = Gobusgo.Reader.read(destination, base_dir: tmp_dir)
      assert content == fixture("lime_v3_vehicle_status")
    end
  end

  describe "a feed with no vehicles" do
    test "empties the view of the system's vehicles", context do
      serve_vehicles(fixture("lime_v3_vehicle_status"))
      {:ok, _recorded} = record(context)
      serve_vehicles(empty_vehicle_status())

      assert {:ok, %{kind: :recorded, vehicle_count: 0}} = record(context)
      assert VehicleStatusView.vehicles(context.view, "lime_seattle") == []
    end
  end

  describe "a feed every version of which answers 404" do
    setup do
      serve(%{})
    end

    test "is a known outcome that stores nothing", %{tmp_dir: tmp_dir} = context do
      assert {:ok, %{kind: :not_published, record_published: true}} = record(context)
      assert stored_destinations(tmp_dir) == []
    end

    test "leaves the view with no vehicles", context do
      {:ok, _found} = record(context)

      assert %{kind: :not_published} = VehicleStatusView.current(context.view, "lime_seattle")
      assert VehicleStatusView.vehicles(context.view, "lime_seattle") == []
    end
  end

  describe "a feed that answers neither 200 nor 404" do
    test "is a fetch failure that stores nothing", %{tmp_dir: tmp_dir} = context do
      Req.Test.stub(@stub_name, &Plug.Conn.send_resp(&1, 500, "server error"))

      assert {:error, {:fetch, %{cause: {:http_status, 500}}}} = record(context)
      assert stored_destinations(tmp_dir) == []
      assert VehicleStatusView.current(context.view, "lime_seattle") == nil
    end
  end
end
