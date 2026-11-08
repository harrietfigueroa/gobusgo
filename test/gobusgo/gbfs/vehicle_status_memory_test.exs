defmodule Gobusgo.Gbfs.VehicleStatusMemoryTest do
  # Measures what one fetch of shared vehicles costs and prints it. The test
  # stores a synthetic 3.0 vehicle file of Lime Seattle's count of vehicles,
  # and of the bound on a fetch, through the local file writer under its
  # temporary directory, has the processor publish it to a view started for
  # the test, and reads the view's table, the view process after a forced
  # collection, the published record, the stored file, and the processing
  # time. It asserts only that the view holds the fetch.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.VehicleStatusBatch
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Publisher.InProcess

  @moduletag :memory
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  # Lime Seattle's count on 2026-11-08, and the bound on one fetch.
  @lime_vehicle_count 12_700
  @bytes_per_mebibyte 1024 * 1024
  @fetched_at ~U[2026-11-08 19:08:00Z]

  defp vehicle(index) do
    %{
      "vehicle_id" => "#{Gobusgo.RequestId.generate()}",
      "lat" => 47.5 + rem(index, 1000) / 4000,
      "lon" => -122.4 + rem(index, 997) / 4000,
      "is_reserved" => false,
      "is_disabled" => rem(index, 50) == 0,
      "current_range_meters" => 1_000 + rem(index, 30_000),
      "vehicle_type_id" => Integer.to_string(rem(index, 4)),
      "last_reported" => "2026-11-08T19:07:55Z"
    }
  end

  defp body(vehicle_count) do
    JSON.encode!(%{
      "last_updated" => "2026-11-08T19:07:58Z",
      "ttl" => 60,
      "version" => "3.0",
      "data" => %{"vehicles" => Enum.map(1..vehicle_count//1, &vehicle/1)}
    })
  end

  defp mebibytes(bytes), do: Float.round(bytes / @bytes_per_mebibyte, 1)

  defp measure(%{tmp_dir: tmp_dir, view: view}, vehicle_count) do
    body = body(vehicle_count)

    stored =
      RawVehicleStatus.build(%{
        system_id: "lime_seattle",
        fetched: %{version: "3.0", body: body, fetched_at: @fetched_at},
        request_id: Gobusgo.RequestId.generate()
      })

    :ok =
      Gobusgo.Writer.write(%{destination: stored.destination, content: stored.content},
        base_dir: tmp_dir
      )

    test = self()

    subscribers = %{
      Records.topic() => {__MODULE__, :apply_and_report, [%{view: view, test: test}]}
    }

    {process_us, {:ok, %{vehicle_count: ^vehicle_count}}} =
      :timer.tc(fn ->
        VehicleStatusBatch.process(stored.destination,
          read_options: [base_dir: tmp_dir],
          publish_options: [backend: InProcess, subscribers: subscribers]
        )
      end)

    assert_receive {:record_bytes, record_bytes}
    assert length(VehicleStatusView.vehicles(view, "lime_seattle")) == vehicle_count
    word_bytes = :erlang.system_info(:wordsize)
    table_bytes = :ets.info(view, :memory) * word_bytes
    view_pid = Process.whereis(view)
    true = :erlang.garbage_collect(view_pid)
    {:memory, view_process_bytes} = Process.info(view_pid, :memory)
    stored_path = Path.join(tmp_dir, stored.destination)

    IO.puts("""

    Shared vehicles, one fetch of #{vehicle_count} vehicles:
      vehicle file as served   #{mebibytes(byte_size(body))} MiB
      stored, gzip             #{mebibytes(File.stat!(stored_path).size)} MiB
      published record         #{mebibytes(record_bytes)} MiB
      view table               #{mebibytes(table_bytes)} MiB
      view process, collected  #{mebibytes(view_process_bytes)} MiB
      processing time          #{Integer.floor_div(process_us, 1_000)} ms
    """)
  end

  @doc false
  def apply_and_report(%{view: view, test: test}, values) do
    send(test, {:record_bytes, Enum.sum(Enum.map(values, &byte_size/1))})
    VehicleStatusView.apply_records(view, values)
  end

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {VehicleStatusView, name: view, pubsub: Gobusgo.PubSub, system_count_max: 1}
    )

    %{view: view}
  end

  test "reports the cost of one fetch of Lime Seattle's vehicles", context do
    measure(context, @lime_vehicle_count)
  end

  test "reports the cost of one fetch at the bound", context do
    measure(context, VehicleStatusBatch.vehicle_count_max())
  end
end
