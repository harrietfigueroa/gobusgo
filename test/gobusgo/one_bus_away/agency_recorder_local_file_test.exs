defmodule Gobusgo.OneBusAway.AgencyRecorderLocalFileTest do
  # Runs record/2 against the local file backend in a temporary directory, with
  # a Req.Test stub serving a JSON fixture, to show a recorded response lands
  # as one readable file and that the backend's create-only rule surfaces. A
  # publisher double defined here acknowledges the event and delivers nothing.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.Writer.LocalFile

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defmodule AcknowledgingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, _options), do: :ok
  end

  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @stub_name AgencyRecorderLocalFile
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}

  setup %{tmp_dir: tmp_dir} do
    body = File.read!(@fixture_path)

    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    options = [
      request_id: "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10",
      fetch_options: [
        plug: {Req.Test, @stub_name},
        max_retries: 0,
        clock: fn -> ~U[2026-10-02 03:15:00Z] end
      ],
      write_options: [backend: LocalFile, base_dir: tmp_dir],
      publish_options: [backend: AcknowledgingPublisher]
    ]

    %{options: options, body: JSON.decode!(body)}
  end

  test "stores the response as one file under the date partition", %{
    tmp_dir: tmp_dir,
    options: options,
    body: body
  } do
    assert {:ok, %{destination: destination}} = AgencyRecorder.record(@settings, options)

    partition = Path.join(tmp_dir, "raw/oba/agencies-with-coverage/dt=2026-10-02")
    assert File.ls!(partition) == [Path.basename(destination)]

    assert %{"body" => ^body} =
             tmp_dir |> Path.join(destination) |> File.read!() |> JSON.decode!()
  end

  test "returns already_exists for a second record under the same name", %{options: options} do
    assert {:ok, _recorded} = AgencyRecorder.record(@settings, options)

    assert AgencyRecorder.record(@settings, options) == {:error, {:write, :already_exists}}
  end
end
