defmodule Gobusgo.OneBusAway.AgencyBatchTest do
  # Drives process/2 through reader and publisher doubles defined here, so
  # every outcome is observed through the reader and publisher contracts with
  # no storage and no broker. Stored responses are produced by
  # RawAgencyResponse.build/1, the form the recorder writes.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :read_errors) do
        %{^destination => reason} -> {:error, reason}
        _other -> fetch(Keyword.fetch!(options, :stored), destination)
      end
    end

    @impl Gobusgo.Reader
    def discover(request, options) do
      send(Keyword.fetch!(options, :recipient), {:discovered, request})
      {:ok, %{destinations: [], cursor: nil}}
    end

    defp fetch(stored, destination) do
      case stored do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end
  end

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :result).(records)
    end
  end

  @metro {"1", "Metro Transit"}
  @regional {"40", "Regional Transit"}
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-10-02 03:15:00Z]

  defp data(agencies) do
    %{
      "limitExceeded" => false,
      "list" =>
        for {id, _name} <- agencies do
          %{
            "agencyId" => id,
            "lat" => 47.5,
            "lon" => -122.25,
            "latSpan" => 0.5,
            "lonSpan" => 0.75
          }
        end,
      "references" => %{
        "agencies" =>
          for {id, name} <- agencies do
            %{
              "id" => id,
              "name" => name,
              "url" => "https://agency.example.test",
              "timezone" => "America/Los_Angeles"
            }
          end
      }
    }
  end

  defp raw(agencies, overrides \\ %{}) do
    %{fetched_at: fetched_at, request_id: request_id} =
      Map.merge(%{fetched_at: @fetched_at, request_id: @request_id}, overrides)

    envelope = %{
      "code" => 200,
      "currentTime" => 1_710_953_797_130,
      "data" => data(agencies),
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

    RawAgencyResponse.build(%{response: response, request_id: request_id})
  end

  defp stored(raws), do: Map.new(raws, &{&1.destination, &1.content})

  defp process(stored, destination, overrides \\ []) do
    read_options =
      Keyword.merge(
        [backend: StoredContent, recipient: self(), stored: stored, read_errors: %{}],
        Keyword.get(overrides, :read_options, [])
      )

    publish_options =
      Keyword.merge(
        [backend: RecordingPublisher, recipient: self(), result: fn _records -> :ok end],
        Keyword.get(overrides, :publish_options, [])
      )

    AgencyBatch.process(destination,
      read_options: read_options,
      publish_options: publish_options
    )
  end

  defp published do
    assert_received {:published, records}
    records
  end

  defp manifest_data([%{key: "manifest", value: value}]), do: JSON.decode!(value)["data"]

  defp invalid(:invalid_json, raw), do: %{raw | content: "{not json"}
  defp invalid(:schema_mismatch, raw), do: %{raw | content: "{}"}

  defp invalid(:hash_mismatch, raw) do
    content =
      raw.content
      |> JSON.decode!()
      |> put_in(["body", "data", "references", "agencies"], [])
      |> JSON.encode!()

    %{raw | content: content}
  end

  defp invalid(:destination_mismatch, raw) do
    %{raw | destination: String.replace(raw.destination, "dt=2026-10-02", "dt=2026-10-03")}
  end

  describe "process/2 publishing" do
    test "publishes one record per agency, then the manifest" do
      raw = raw([@regional, @metro])

      assert process(stored([raw]), raw.destination) ==
               {:ok,
                %{
                  destination: raw.destination,
                  request_id: @request_id,
                  fetched_at: @fetched_at,
                  agency_count: 2
                }}

      assert Enum.map(published(), & &1.key) == ["agency/1", "agency/40"]
      assert manifest_data(published())["agencyIds"] == ["1", "40"]
      refute_received {:published, _records}
    end

    test "publishes the manifest alone for a fetch without agencies" do
      raw = raw([])

      assert {:ok, %{agency_count: 0}} = process(stored([raw]), raw.destination)

      assert manifest_data(published())["agencyIds"] == []
      refute_received {:published, _records}
    end

    test "reads the file the destination names and lists nothing" do
      raw = raw([@metro])
      other = raw([@regional], %{request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"})

      assert {:ok, %{agency_count: 1}} = process(stored([raw, other]), raw.destination)

      assert Enum.map(published(), & &1.key) == ["agency/1"]
      refute_received {:discovered, _request}
    end

    test "publishes the same records again for a repeated input" do
      raw = raw([@regional, @metro])

      assert {:ok, first} = process(stored([raw]), raw.destination)
      first_records = [published(), published()]

      assert process(stored([raw]), raw.destination) == {:ok, first}
      assert [published(), published()] == first_records
    end

    test "leaves an agency that dropped out of a later fetch out of its manifest" do
      earlier = raw([@metro, @regional])

      later =
        raw([@metro], %{
          fetched_at: ~U[2026-10-02 03:16:00Z],
          request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
        })

      stored = stored([earlier, later])

      assert {:ok, %{agency_count: 2}} = process(stored, earlier.destination)
      assert Enum.map(published(), & &1.key) == ["agency/1", "agency/40"]
      assert manifest_data(published())["agencyIds"] == ["1", "40"]

      assert {:ok, %{agency_count: 1}} = process(stored, later.destination)
      assert Enum.map(published(), & &1.key) == ["agency/1"]
      assert manifest_data(published())["agencyIds"] == ["1"]
    end

    test "logs the outcome once at info" do
      raw = raw([@metro])

      log = capture_log([metadata: :all], fn -> process(stored([raw]), raw.destination) end)

      assert log =~ "[info]"
      assert log =~ "Agency batch published"
      assert log =~ "request_id=#{@request_id}"
      assert log =~ "agency_count=1"
    end
  end

  describe "process/2 invalid input" do
    for {reason, error_code} <- [
          invalid_json: "INVALID_JSON",
          schema_mismatch: "SCHEMA_MISMATCH",
          hash_mismatch: "HASH_MISMATCH",
          destination_mismatch: "DESTINATION_MISMATCH"
        ] do
      test "returns a permanent #{error_code} failure and publishes nothing for #{reason}" do
        raw = invalid(unquote(reason), raw([@metro]))

        assert process(stored([raw]), raw.destination) ==
                 {:error,
                  %{
                    class: :permanent,
                    error_code: unquote(error_code),
                    stage: :parse,
                    reason: unquote(reason)
                  }}

        refute_received {:published, _records}
      end
    end
  end

  describe "process/2 read failures" do
    for {reason, class} <- [
          io_failure: :transient,
          permission_denied: :transient,
          not_found: :permanent,
          content_too_large: :permanent
        ] do
      test "returns a #{class} READ_FAILURE and publishes nothing for #{reason}" do
        raw = raw([@metro])

        result =
          process(stored([raw]), raw.destination,
            read_options: [read_errors: %{raw.destination => unquote(reason)}]
          )

        assert result ==
                 {:error,
                  %{
                    class: unquote(class),
                    error_code: "READ_FAILURE",
                    stage: :read,
                    reason: unquote(reason)
                  }}

        refute_received {:published, _records}
      end
    end

    test "returns a permanent READ_FAILURE for a destination the reader rejects" do
      result =
        process(%{}, "elsewhere",
          read_options: [read_errors: %{"elsewhere" => {:invalid_destination, :redirected}}]
        )

      assert {:error, %{class: :permanent, error_code: "READ_FAILURE", stage: :read}} = result
    end
  end

  describe "process/2 publish failures" do
    for {reason, class} <- [
          timeout: :transient,
          unavailable: :transient,
          unknown_topic: :transient,
          record_too_large: :permanent
        ] do
      test "returns a #{class} WRITE_FAILURE and publishes no manifest when #{reason} stops the agency records" do
        raw = raw([@metro])

        result =
          process(stored([raw]), raw.destination,
            publish_options: [result: fn _records -> {:error, unquote(reason)} end]
          )

        assert result ==
                 {:error,
                  %{
                    class: unquote(class),
                    error_code: "WRITE_FAILURE",
                    stage: :publish_agencies,
                    reason: unquote(reason)
                  }}

        assert [%{key: "agency/1"}] = published()
        refute_received {:published, _records}
      end
    end

    test "returns a failure at the manifest after the agency records are published" do
      raw = raw([@metro])

      fail_manifest = fn
        [%{key: "manifest"}] -> {:error, :timeout}
        _records -> :ok
      end

      result =
        process(stored([raw]), raw.destination, publish_options: [result: fail_manifest])

      assert result ==
               {:error,
                %{
                  class: :transient,
                  error_code: "WRITE_FAILURE",
                  stage: :publish_manifest,
                  reason: :timeout
                }}

      assert [%{key: "agency/1"}] = published()
      assert [%{key: "manifest"}] = published()
    end

    test "logs nothing for a failure, which returns to the caller" do
      raw = raw([@metro])

      log =
        capture_log([metadata: :all], fn ->
          assert {:error, %{stage: :publish_agencies}} =
                   process(stored([raw]), raw.destination,
                     publish_options: [result: fn _records -> {:error, :timeout} end]
                   )
        end)

      assert log == ""
    end
  end
end
