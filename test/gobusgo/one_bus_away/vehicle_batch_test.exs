defmodule Gobusgo.OneBusAway.VehicleBatchTest do
  # Drives process/2 through reader and publisher doubles defined here and a
  # vehicle view of the test's own, so every outcome is observed through the
  # reader and publisher contracts with no storage and no broker. Stored
  # responses are produced by RawVehicleResponse.build/1, the form the
  # recorder writes.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.OneBusAway.VehicleBatch
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => {:error, reason}} -> {:error, reason}
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :result).(records)
    end
  end

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-10-02 03:15:00Z]

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({VehicleView, name: view, pubsub: Gobusgo.PubSub})
    %{view: view}
  end

  defp raw(vehicle_ids, overrides \\ %{}) do
    %{fetched_at: fetched_at, request_id: request_id} =
      Map.merge(%{fetched_at: @fetched_at, request_id: @request_id}, overrides)

    list =
      for id <- vehicle_ids do
        %{"vehicleId" => id, "lastUpdateTime" => 0, "lastLocationUpdateTime" => 0}
      end

    response = %{
      agency_id: "40",
      vehicles: [],
      envelope: %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => %{
          "limitExceeded" => false,
          "list" => list,
          "references" => %{"routes" => [], "trips" => []}
        },
        "text" => "OK",
        "version" => 2
      },
      fetched_at: fetched_at,
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawVehicleResponse.build(%{response: response, request_id: request_id})
  end

  # The backend holds a gzip stream under a compressed destination.
  defp process(raw, view, options \\ []) do
    stored = Keyword.get(options, :stored, %{raw.destination => :zlib.gzip(raw.content)})
    result = Keyword.get(options, :result, fn _records -> :ok end)

    VehicleBatch.process(raw.destination,
      view: view,
      read_options: [backend: StoredContent, stored: stored],
      publish_options: [backend: RecordingPublisher, recipient: self(), result: result]
    )
  end

  defp published_calls(calls \\ []) do
    receive do
      {:published, records} -> published_calls(calls ++ [records])
    after
      0 -> calls
    end
  end

  # Makes `view` hold the fetch of `raw` the way the state topic would.
  defp apply_to_view(raw, view) do
    {:ok, fetch} = RawVehicleResponse.parse(Map.take(raw, [:destination, :content]))
    %{vehicles: vehicles, manifest: manifest} = Records.build(fetch)
    :ok = VehicleView.apply_records(view, Enum.map(vehicles ++ [manifest], & &1.value))
  end

  defp decoded(records), do: Enum.map(records, &elem(Records.decode(&1.value), 1))

  describe "process/2 success" do
    test "publishes the vehicle records, then the manifest", %{view: view} do
      raw = raw(["40_b", "40_a"])

      assert process(raw, view) ==
               {:ok,
                %{
                  destination: raw.destination,
                  agency_id: "40",
                  request_id: @request_id,
                  fetched_at: @fetched_at,
                  vehicle_count: 2,
                  tombstone_count: 0
                }}

      assert [vehicles, [manifest]] = published_calls()
      assert Enum.map(vehicles, & &1.key) == ["vehicle/40/40_a", "vehicle/40/40_b"]
      assert manifest.key == "manifest/40"

      assert [{:manifest, %{vehicle_ids: ["40_a", "40_b"], destination: destination}}] =
               decoded([manifest])

      assert destination == raw.destination
    end

    test "publishes the manifest alone for a fetch without vehicles", %{view: view} do
      assert {:ok, %{vehicle_count: 0}} = process(raw([]), view)

      assert [[%{key: "manifest/40"}]] = published_calls()
    end

    test "publishes a fetch larger than one publisher call completely, manifest last",
         %{view: view} do
      count = Publisher.record_count_max() * 2 + 1
      ids = for index <- 1..count, do: "40_#{index}"

      assert {:ok, %{vehicle_count: ^count}} = process(raw(ids), view)

      assert [first, second, third, [manifest]] = published_calls()
      assert Enum.map([first, second, third], &length/1) == [1000, 1000, 1]

      assert Enum.sort(Enum.map(first ++ second ++ third, & &1.key)) ==
               Enum.sort(Enum.map(ids, &("vehicle/40/" <> &1)))

      assert [{:manifest, %{vehicle_ids: manifest_ids}}] = decoded([manifest])
      assert length(manifest_ids) == count
    end
  end

  describe "process/2 tombstones" do
    @after_grace %{
      fetched_at: ~U[2026-10-02 03:20:01Z],
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
    }
    @within_grace %{
      fetched_at: ~U[2026-10-02 03:20:00Z],
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
    }

    test "publishes a tombstone, before the manifest, for a vehicle absent past the grace period",
         %{view: view} do
      apply_to_view(raw(["40_a", "40_gone"]), view)

      assert {:ok, %{vehicle_count: 1, tombstone_count: 1}} =
               process(raw(["40_a"], @after_grace), view)

      assert [[%{key: "vehicle/40/40_a"}], [tombstone], [%{key: "manifest/40"}]] =
               published_calls()

      assert tombstone == %{
               topic: "oba.vehicles-for-agency.state",
               key: "vehicle/40/40_gone",
               value: "",
               headers: []
             }
    end

    test "publishes no tombstone for a vehicle absent within the grace period", %{view: view} do
      apply_to_view(raw(["40_a", "40_gone"]), view)

      assert {:ok, %{tombstone_count: 0}} = process(raw(["40_a"], @within_grace), view)

      assert [[%{key: "vehicle/40/40_a"}], [%{key: "manifest/40"}]] = published_calls()
    end

    test "publishes no tombstone for a vehicle that is in the fetch again", %{view: view} do
      apply_to_view(raw(["40_a", "40_back"]), view)

      assert {:ok, %{tombstone_count: 0}} =
               process(raw(["40_a", "40_back"], @after_grace), view)
    end

    test "publishes no tombstone while the view is not running" do
      assert {:ok, %{tombstone_count: 0}} = process(raw(["40_a"]), __MODULE__.NotStarted)
    end
  end

  describe "process/2 failures" do
    test "returns a permanent read failure for a destination that holds nothing",
         %{view: view} do
      assert process(raw(["40_a"]), view, stored: %{}) ==
               {:error,
                %{class: :permanent, error_code: "READ_FAILURE", stage: :read, reason: :not_found}}

      assert published_calls() == []
    end

    test "returns a transient read failure for an input and output failure", %{view: view} do
      raw = raw(["40_a"])

      assert {:error, %{class: :transient, stage: :read, reason: :io_failure}} =
               process(raw, view, stored: %{raw.destination => {:error, :io_failure}})
    end

    test "returns a permanent parse failure for content that is not a stored response",
         %{view: view} do
      raw = raw(["40_a"])

      assert process(raw, view, stored: %{raw.destination => :zlib.gzip("{")}) ==
               {:error,
                %{
                  class: :permanent,
                  error_code: "INVALID_JSON",
                  stage: :parse,
                  reason: :invalid_json
                }}
    end

    test "publishes no manifest when a chunk of vehicle records is not published",
         %{view: view} do
      ids = for index <- 1..(Publisher.record_count_max() + 1), do: "40_#{index}"

      result = fn records ->
        if length(records) == 1, do: {:error, :timeout}, else: :ok
      end

      assert process(raw(ids), view, result: result) ==
               {:error,
                %{
                  class: :transient,
                  error_code: "WRITE_FAILURE",
                  stage: :publish_vehicles,
                  reason: :timeout
                }}

      assert [_first, _second] = published_calls()
    end

    test "publishes no manifest when the tombstones are not published", %{view: view} do
      apply_to_view(raw(["40_a", "40_gone"]), view)

      result = fn [%{value: value} | _rest] ->
        if value == "", do: {:error, :unavailable}, else: :ok
      end

      assert {:error, %{class: :transient, stage: :publish_tombstones, reason: :unavailable}} =
               process(raw(["40_a"], @after_grace), view, result: result)

      assert [_vehicles, _tombstones] = published_calls()
    end

    test "returns the failure of the manifest", %{view: view} do
      result = fn [%{key: key} | _rest] ->
        if key == "manifest/40", do: {:error, :record_too_large}, else: :ok
      end

      assert {:error, %{class: :permanent, stage: :publish_manifest, reason: :record_too_large}} =
               process(raw(["40_a"]), view, result: result)
    end
  end
end
