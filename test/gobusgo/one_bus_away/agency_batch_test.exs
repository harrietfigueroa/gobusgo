defmodule Gobusgo.OneBusAway.AgencyBatchTest do
  # Drives process/2 through reader and writer doubles defined here, so every
  # outcome is observed through the reader and writer contracts with no
  # storage. Stored responses are produced by RawAgencyResponse.build/1, the
  # form the recorder writes.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      send(Keyword.fetch!(options, :recipient), {:read, destination})

      case Keyword.fetch!(options, :read_errors) do
        %{^destination => reason} -> {:error, reason}
        _other -> fetch(Keyword.fetch!(options, :stored), destination)
      end
    end

    @impl Gobusgo.Reader
    def discover(%{prefix: prefix, limit: limit, order: order, cursor: cursor}, options) do
      case Keyword.fetch!(options, :discover_error) do
        nil ->
          matching =
            options
            |> Keyword.fetch!(:stored)
            |> Map.keys()
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.sort(direction(order))
            |> Enum.filter(&after_cursor?(&1, cursor, order))

          page = Enum.take(matching, limit)
          next = if length(matching) > limit, do: List.last(page), else: nil
          {:ok, %{destinations: page, cursor: next}}

        reason ->
          {:error, reason}
      end
    end

    defp fetch(stored, destination) do
      case stored do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end

    defp direction(:ascending), do: :asc
    defp direction(:descending), do: :desc

    defp after_cursor?(_destination, nil, _order), do: true
    defp after_cursor?(destination, cursor, :ascending), do: destination > cursor
    defp after_cursor?(destination, cursor, :descending), do: destination < cursor
  end

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:written, request})
      Keyword.fetch!(options, :result)
    end
  end

  @window %{start_at: ~U[2026-10-02 03:00:00Z], end_at: ~U[2026-10-02 04:00:00Z]}
  @batch_id "20261002T030000Z-20261002T040000Z"
  @now ~U[2026-10-02 04:05:00Z]
  @trigger_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @partition "raw/oba/agencies-with-coverage/dt=2026-10-02/"

  defp data(name) do
    %{
      "limitExceeded" => false,
      "list" => [
        %{"agencyId" => "1", "lat" => 47.5, "lon" => -122.25, "latSpan" => 0.5, "lonSpan" => 0.75}
      ],
      "references" => %{
        "agencies" => [
          %{
            "id" => "1",
            "name" => name,
            "url" => "https://metro.example.test",
            "timezone" => "America/Los_Angeles"
          }
        ]
      }
    }
  end

  defp request_id(index) do
    suffix = index |> Integer.to_string(16) |> String.pad_leading(12, "0")
    "0199c4a2-7e1b-7a3f-9d20-#{String.downcase(suffix)}"
  end

  defp raw(fetched_at, index, name \\ "Metro Transit") do
    envelope = %{
      "code" => 200,
      "currentTime" => 1_710_953_797_130,
      "data" => data(name),
      "text" => "OK",
      "version" => 2
    }

    response = %{
      agencies: [],
      envelope: envelope,
      fetched_at: fetched_at,
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawAgencyResponse.build(%{response: response, request_id: request_id(index)})
  end

  defp stored(raws), do: Map.new(raws, &{&1.destination, &1.content})

  defp process(stored, overrides \\ []) do
    {request_overrides, option_overrides} = Keyword.split(overrides, [:window, :reprocess])

    read_options =
      Keyword.merge(
        [
          backend: StoredContent,
          recipient: self(),
          stored: stored,
          read_errors: %{},
          discover_error: nil
        ],
        Keyword.get(option_overrides, :read_options, [])
      )

    write_options =
      Keyword.merge(
        [backend: RecordingBackend, recipient: self(), result: :ok],
        Keyword.get(option_overrides, :write_options, [])
      )

    request =
      Map.merge(
        %{window: @window, trigger_id: @trigger_id, reprocess: false},
        Map.new(request_overrides)
      )

    AgencyBatch.process(request,
      read_options: read_options,
      write_options: write_options,
      clock: Keyword.get(option_overrides, :clock, fn -> @now end)
    )
  end

  defp written_meta do
    assert_received {:written, %{content: content}}
    content |> JSON.decode!() |> Map.fetch!("meta")
  end

  describe "process/2 publishing" do
    test "publishes one output from the inputs fetched inside the window" do
      before_window = raw(~U[2026-10-02 02:59:59Z], 1)
      first = raw(~U[2026-10-02 03:00:00Z], 2)
      last = raw(~U[2026-10-02 03:59:59Z], 3, "Metro Transit Renamed")
      at_end = raw(~U[2026-10-02 04:00:00Z], 4)

      assert {:ok, result} = process(stored([before_window, first, last, at_end]))

      assert result == %{
               outcome: :published,
               batch_id: @batch_id,
               destination:
                 "processed/oba/agencies/#{@batch_id}_20261002T030000Z_20261002T035959Z_20261002T040500Z.json",
               input_count: 2,
               skipped_count: 0,
               duplicate_count: 0
             }

      assert_received {:written, %{destination: destination, content: content}}
      assert destination == result.destination

      assert %{"agencies" => [%{"name" => "Metro Transit Renamed"}], "meta" => meta} =
               JSON.decode!(content)

      assert Enum.map(meta["inputs"], & &1["destination"]) == [
               first.destination,
               last.destination
             ]

      assert meta["triggerId"] == @trigger_id
      assert meta["inputFileCount"] == 2
    end

    test "records an input with the hash of an earlier input as a duplicate" do
      first = raw(~U[2026-10-02 03:10:00Z], 1)
      second = raw(~U[2026-10-02 03:20:00Z], 2)

      assert {:ok, %{outcome: :published, input_count: 2, duplicate_count: 1}} =
               process(stored([first, second]))

      assert Enum.map(written_meta()["inputs"], & &1["duplicate"]) == [false, true]
    end

    test "reads the partition of every date the window touches" do
      window = %{start_at: ~U[2026-10-02 23:00:00Z], end_at: ~U[2026-10-03 01:00:00Z]}
      late = raw(~U[2026-10-02 23:30:00Z], 1)
      early = raw(~U[2026-10-03 00:30:00Z], 2)

      assert {:ok, %{outcome: :published, input_count: 2}} =
               process(stored([late, early]),
                 window: window,
                 clock: fn -> ~U[2026-10-03 02:00:00Z] end
               )
    end

    test "reads every input of a window larger than one page" do
      raws =
        for index <- 0..1_000 do
          raw(DateTime.add(~U[2026-10-02 03:00:00Z], index, :second), index)
        end

      assert {:ok, %{outcome: :published, input_count: 1_001, duplicate_count: 1_000}} =
               process(stored(raws))
    end

    test "logs the outcome once at info" do
      log =
        capture_log([metadata: :all], fn ->
          process(stored([raw(~U[2026-10-02 03:10:00Z], 1)]))
        end)

      assert log =~ "[info]"
      assert log =~ "Agency batch finished"
      assert log =~ "outcome=published"
      assert log =~ "batch_id=#{@batch_id}"
    end
  end

  describe "process/2 skipped inputs" do
    test "publishes from the valid inputs and records each skipped one" do
      valid = raw(~U[2026-10-02 03:10:00Z], 1)
      corrupt = %{raw(~U[2026-10-02 03:20:00Z], 2) | content: "{not json"}
      unnamed = %{destination: @partition <> "notes.json", content: "{}"}

      assert {:ok, %{outcome: :published_with_skips, input_count: 1, skipped_count: 2}} =
               process(stored([valid, corrupt, unnamed]))

      meta = written_meta()

      assert meta["skipped"] == [
               %{"destination" => corrupt.destination, "reason" => "invalid_json"},
               %{"destination" => unnamed.destination, "reason" => "destination_mismatch"}
             ]

      assert meta["inputFileCount"] == 3
      refute_received {:read, "raw/oba/agencies-with-coverage/dt=2026-10-02/notes.json"}
    end

    test "logs published with skips once at warning" do
      valid = raw(~U[2026-10-02 03:10:00Z], 1)
      corrupt = %{raw(~U[2026-10-02 03:20:00Z], 2) | content: "{not json"}

      log = capture_log([metadata: :all], fn -> process(stored([valid, corrupt])) end)

      assert log =~ "[warning]"
      assert log =~ "Agency batch published with skips"
      assert log =~ "skipped_count=1"
    end

    test "fails and writes nothing when every input is invalid" do
      corrupt = %{raw(~U[2026-10-02 03:20:00Z], 2) | content: "{not json"}

      assert process(stored([corrupt])) == {:error, :all_inputs_invalid}
      refute_received {:written, _request}
    end
  end

  describe "process/2 without work" do
    test "returns no_input and writes nothing for a window without inputs" do
      outside = raw(~U[2026-10-02 05:00:00Z], 1)

      assert process(stored([outside])) ==
               {:ok,
                %{
                  outcome: :no_input,
                  batch_id: @batch_id,
                  destination: nil,
                  input_count: 0,
                  skipped_count: 0,
                  duplicate_count: 0
                }}

      refute_received {:written, _request}
    end

    test "returns window_open and reads nothing before the window ends" do
      result =
        process(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
          clock: fn -> ~U[2026-10-02 03:59:59Z] end
        )

      assert result == {:error, :window_open}
      refute_received {:read, _destination}
      refute_received {:written, _request}
    end

    test "returns already_published and reads no input when the window has an output" do
      earlier =
        "processed/oba/agencies/#{@batch_id}_20261002T030000Z_20261002T035900Z_20261002T040100Z.json"

      later =
        "processed/oba/agencies/#{@batch_id}_20261002T030000Z_20261002T035900Z_20261002T040200Z.json"

      stored =
        [raw(~U[2026-10-02 03:10:00Z], 1)]
        |> stored()
        |> Map.merge(%{earlier => "{}", later => "{}"})

      assert {:ok, %{outcome: :already_published, destination: ^later, input_count: 0}} =
               process(stored)

      refute_received {:read, _destination}
      refute_received {:written, _request}
    end

    test "ignores the outputs of other windows" do
      other = "processed/oba/agencies/20261002T020000Z-20261002T030000Z_a_b_c.json"
      stored = [raw(~U[2026-10-02 03:10:00Z], 1)] |> stored() |> Map.put(other, "{}")

      assert {:ok, %{outcome: :published}} = process(stored)
    end

    test "publishes again for an explicit reprocess of a published window" do
      existing =
        "processed/oba/agencies/#{@batch_id}_20261002T030000Z_20261002T035900Z_20261002T040100Z.json"

      stored = [raw(~U[2026-10-02 03:10:00Z], 1)] |> stored() |> Map.put(existing, "{}")

      assert {:ok, %{outcome: :published, destination: destination}} =
               process(stored, reprocess: true)

      assert destination != existing
      assert_received {:written, %{destination: ^destination}}
    end
  end

  describe "process/2 failures" do
    for reason <- [:io_failure, :not_found, :permission_denied, :content_too_large] do
      test "aborts and writes nothing when a read returns #{reason}" do
        first = raw(~U[2026-10-02 03:10:00Z], 1)
        second = raw(~U[2026-10-02 03:20:00Z], 2)

        result =
          process(stored([first, second]),
            read_options: [read_errors: %{second.destination => unquote(reason)}]
          )

        assert result == {:error, {:read, unquote(reason)}}
        refute_received {:written, _request}
      end
    end

    test "aborts when discovery fails" do
      result =
        process(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
          read_options: [discover_error: :io_failure]
        )

      assert result == {:error, {:read, :io_failure}}
      refute_received {:written, _request}
    end

    test "returns the writer's reason when the write fails" do
      result =
        process(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
          write_options: [result: {:error, :storage_full}]
        )

      assert result == {:error, {:write, :storage_full}}
    end

    test "returns too_many_inputs and reads nothing for a window over the input bound" do
      raws =
        for index <- 0..AgencyBatch.input_count_max() do
          raw(DateTime.add(~U[2026-10-02 00:00:00Z], index, :second), index)
        end

      window = %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}

      result = process(stored(raws), window: window, clock: fn -> ~U[2026-10-03 00:05:00Z] end)

      assert result == {:error, :too_many_inputs}
      refute_received {:read, _destination}
      refute_received {:written, _request}
    end

    test "logs a failure once at error with its reason" do
      log =
        capture_log([metadata: :all], fn ->
          process(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
            write_options: [result: {:error, :storage_full}]
          )
        end)

      assert log =~ "[error]"
      assert log =~ "Agency batch failed"
      assert log =~ "storage_full"
      assert log =~ "trigger_id=#{@trigger_id}"
    end
  end

  describe "process/2 assertions" do
    test "raises for a trigger identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/trigger_id/, fn ->
        AgencyBatch.process(%{window: @window, trigger_id: "trigger", reprocess: false}, [])
      end
    end

    test "raises for a window that ends before it starts" do
      window = %{start_at: @window.end_at, end_at: @window.start_at}

      assert_raise AssertionError, ~r/before/, fn -> process(%{}, window: window) end
    end

    test "raises for a reprocess flag that is not a boolean" do
      assert_raise AssertionError, ~r/reprocess/, fn -> process(%{}, reprocess: :yes) end
    end
  end
end
