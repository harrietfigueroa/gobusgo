defmodule Gobusgo.OneBusAway.ReconciliationTest do
  # Drives republish/2 through reader and publisher doubles defined here, so
  # every outcome is observed through the reader and publisher contracts with
  # no storage and no broker. Stored responses are produced by
  # RawAgencyResponse.build/1, the form the recorder writes.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.Reconciliation
  alias Gobusgo.RequestId

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

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :result)
    end
  end

  @dataset "oba/agencies-with-coverage"
  @range %{start_at: ~U[2026-10-02 03:00:00Z], end_at: ~U[2026-10-02 04:00:00Z]}
  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @partition "raw/oba/agencies-with-coverage/dt=2026-10-02/"

  defp request_id(index) do
    suffix = index |> Integer.to_string(16) |> String.pad_leading(12, "0")
    "0199c4a2-7e1b-7a3f-9d20-#{String.downcase(suffix)}"
  end

  defp raw(fetched_at, index) do
    data = %{
      "limitExceeded" => false,
      "list" => [
        %{"agencyId" => "1", "lat" => 47.5, "lon" => -122.25, "latSpan" => 0.5, "lonSpan" => 0.75}
      ],
      "references" => %{
        "agencies" => [
          %{
            "id" => "1",
            "name" => "Metro Transit",
            "url" => "https://metro.example.test",
            "timezone" => "America/Los_Angeles"
          }
        ]
      }
    }

    envelope = %{
      "code" => 200,
      "currentTime" => 1_710_953_797_130,
      "data" => data,
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

  defp republish(stored, overrides \\ []) do
    {request_overrides, option_overrides} = Keyword.split(overrides, [:dataset, :range])

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

    publish_options =
      Keyword.merge(
        [backend: RecordingPublisher, recipient: self(), result: :ok],
        Keyword.get(option_overrides, :publish_options, [])
      )

    request = Map.merge(%{dataset: @dataset, range: @range}, Map.new(request_overrides))

    Reconciliation.republish(request,
      read_options: read_options,
      publish_options: publish_options,
      event_id: Keyword.get(option_overrides, :event_id, fn -> @event_id end)
    )
  end

  defp published_events do
    assert_received {:published, records}
    Enum.map(records, &JSON.decode!(&1.value))
  end

  describe "republish/2 publishing" do
    test "publishes one event per response fetched inside the range, in destination order" do
      before_range = raw(~U[2026-10-02 02:59:59Z], 1)
      first = raw(~U[2026-10-02 03:00:00Z], 2)
      last = raw(~U[2026-10-02 03:59:59Z], 3)
      at_end = raw(~U[2026-10-02 04:00:00Z], 4)

      assert republish(stored([before_range, first, last, at_end])) ==
               {:ok, %{published_count: 2, skipped: []}}

      assert Enum.map(published_events(), & &1["data"]["destination"]) ==
               [first.destination, last.destination]

      refute_received {:published, _records}
    end

    test "publishes a response stored event that refers to the stored response" do
      raw = raw(~U[2026-10-02 03:15:00Z], 1)

      assert {:ok, %{published_count: 1}} = republish(stored([raw]))

      assert published_events() == [
               %{
                 "specversion" => "1.0",
                 "id" => @event_id,
                 "source" => "/gobusgo/reconciliation/oba/agencies-with-coverage",
                 "type" => "gobusgo.response.stored.v1",
                 "time" => "2026-10-02T03:15:00Z",
                 "subject" => raw.destination,
                 "datacontenttype" => "application/json",
                 "partitionkey" => @dataset,
                 "data" => %{
                   "dataset" => @dataset,
                   "destination" => raw.destination,
                   "fetchedAt" => "2026-10-02T03:15:00Z",
                   "dataSha256" => raw.data_sha256,
                   "requestId" => request_id(1)
                 }
               }
             ]
    end

    test "gives each event its own UUID version 7 by default" do
      raws = [raw(~U[2026-10-02 03:10:00Z], 1), raw(~U[2026-10-02 03:20:00Z], 2)]

      assert {:ok, %{published_count: 2}} =
               republish(stored(raws), event_id: &RequestId.generate/0)

      ids = Enum.map(published_events(), & &1["id"])
      assert Enum.all?(ids, &RequestId.valid?/1)
      assert ids == Enum.uniq(ids)
    end

    test "reads the partition of every date the range touches" do
      range = %{start_at: ~U[2026-10-02 23:00:00Z], end_at: ~U[2026-10-03 01:00:00Z]}
      late = raw(~U[2026-10-02 23:30:00Z], 1)
      early = raw(~U[2026-10-03 00:30:00Z], 2)

      assert {:ok, %{published_count: 2}} = republish(stored([late, early]), range: range)
    end

    test "publishes every response of a range larger than one page, in bounded calls" do
      raws =
        for index <- 0..1_000 do
          raw(DateTime.add(~U[2026-10-02 03:00:00Z], index, :second), index)
        end

      assert {:ok, %{published_count: 1_001}} = republish(stored(raws))

      assert length(published_events()) == 1_000
      assert length(published_events()) == 1
    end

    test "publishes nothing for a range without responses" do
      outside = raw(~U[2026-10-02 05:00:00Z], 1)

      assert republish(stored([outside])) == {:ok, %{published_count: 0, skipped: []}}
      refute_received {:published, _records}
    end

    test "logs the outcome once at info" do
      log =
        capture_log([metadata: :all], fn ->
          republish(stored([raw(~U[2026-10-02 03:10:00Z], 1)]))
        end)

      assert log =~ "[info]"
      assert log =~ "Reconciliation finished"
      assert log =~ "published_count=1"
      assert log =~ "dataset=#{@dataset}"
    end
  end

  describe "republish/2 skipped responses" do
    test "publishes the valid responses and returns each skipped one with its reason" do
      valid = raw(~U[2026-10-02 03:10:00Z], 1)
      corrupt = %{raw(~U[2026-10-02 03:20:00Z], 2) | content: "{not json"}
      unnamed = %{destination: @partition <> "notes.json", content: "{}"}

      assert republish(stored([valid, corrupt, unnamed])) ==
               {:ok,
                %{
                  published_count: 1,
                  skipped: [
                    %{destination: corrupt.destination, reason: :invalid_json},
                    %{destination: unnamed.destination, reason: :destination_mismatch}
                  ]
                }}

      assert [%{"data" => %{"destination" => destination}}] = published_events()
      assert destination == valid.destination
      refute_received {:read, "raw/oba/agencies-with-coverage/dt=2026-10-02/notes.json"}
    end

    test "logs finished with skips once at warning" do
      valid = raw(~U[2026-10-02 03:10:00Z], 1)
      corrupt = %{raw(~U[2026-10-02 03:20:00Z], 2) | content: "{not json"}

      log = capture_log([metadata: :all], fn -> republish(stored([valid, corrupt])) end)

      assert log =~ "[warning]"
      assert log =~ "Reconciliation finished with skips"
      assert log =~ "skipped_count=1"
    end
  end

  describe "republish/2 failures" do
    test "returns unknown_dataset and discovers nothing for a dataset it does not know" do
      result = republish(stored([raw(~U[2026-10-02 03:10:00Z], 1)]), dataset: "oba/stops")

      assert result == {:error, :unknown_dataset}
      refute_received {:read, _destination}
      refute_received {:published, _records}
    end

    for reason <- [:io_failure, :not_found, :permission_denied, :content_too_large] do
      test "aborts and publishes nothing when a read returns #{reason}" do
        first = raw(~U[2026-10-02 03:10:00Z], 1)
        second = raw(~U[2026-10-02 03:20:00Z], 2)

        result =
          republish(stored([first, second]),
            read_options: [read_errors: %{second.destination => unquote(reason)}]
          )

        assert result == {:error, {:read, unquote(reason)}}
        refute_received {:published, _records}
      end
    end

    test "aborts when discovery fails" do
      result =
        republish(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
          read_options: [discover_error: :io_failure]
        )

      assert result == {:error, {:read, :io_failure}}
      refute_received {:published, _records}
    end

    test "returns the publisher's reason when a publish fails" do
      result =
        republish(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
          publish_options: [result: {:error, :timeout}]
        )

      assert result == {:error, {:publish, :timeout}}
    end

    test "returns too_many_files and reads nothing for a range over the file bound" do
      raws =
        for index <- 0..Reconciliation.file_count_max() do
          raw(DateTime.add(~U[2026-10-02 00:00:00Z], index, :second), index)
        end

      range = %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}

      assert republish(stored(raws), range: range) == {:error, :too_many_files}
      refute_received {:read, _destination}
      refute_received {:published, _records}
    end

    test "logs a failure once at error with its reason" do
      log =
        capture_log([metadata: :all], fn ->
          republish(stored([raw(~U[2026-10-02 03:10:00Z], 1)]),
            publish_options: [result: {:error, :timeout}]
          )
        end)

      assert log =~ "[error]"
      assert log =~ "Reconciliation failed"
      assert log =~ "timeout"
      assert log =~ "dataset=#{@dataset}"
    end
  end

  describe "republish/2 assertions" do
    test "raises for a range that ends before it starts" do
      range = %{start_at: @range.end_at, end_at: @range.start_at}

      assert_raise AssertionError, ~r/before/, fn -> republish(%{}, range: range) end
    end

    test "raises for an event identifier source that is not a function" do
      assert_raise AssertionError, ~r/event_id/, fn -> republish(%{}, event_id: @event_id) end
    end
  end
end
