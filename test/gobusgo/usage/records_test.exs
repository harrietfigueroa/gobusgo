defmodule Gobusgo.Usage.RecordsTest do
  # Verifies the record of an ended connection and the file of a batch as
  # pure functions of what they are given, and that a record has no field
  # beyond the ones the module lists.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Compression
  alias Gobusgo.Destination
  alias Gobusgo.Schema
  alias Gobusgo.Usage.Records

  @connected_at ~U[2026-10-08 17:00:00.250Z]
  @connection %{
    page: "vehicle",
    reconnect: false,
    device_class: "mobile",
    browser_family: "safari",
    viewport_width_bucket: "under-480",
    language: "en",
    referrer_host: "example.org"
  }
  @ended %{connection: @connection, filter: %{}, connected_at: @connected_at, duration_ms: 90_000}

  defp record(changes \\ %{}), do: Records.build(Map.merge(@ended, changes))

  describe "build/1" do
    test "holds the facts of the connection" do
      assert record(%{filter: %{"agency" => ["1", "40"]}}) == %{
               "browserFamily" => "safari",
               "connectedAt" => "2026-10-08T17:00:00.250Z",
               "deviceClass" => "mobile",
               "durationMs" => 90_000,
               "filter" => %{"agency" => ["1", "40"]},
               "filterValueOmittedCount" => 0,
               "language" => "en",
               "page" => "vehicle",
               "reconnect" => false,
               "referrerHost" => "example.org",
               "viewportWidthBucket" => "under-480"
             }
    end

    test "has exactly the fields the module lists" do
      assert record() |> Map.keys() |> Enum.sort() == Records.fields()
    end

    test "has no field for an address, a user agent, or an identifier" do
      for field <- Records.fields() do
        refute String.downcase(field) =~ ~r/ip|address|agent|id$|session|visitor|user/
      end
    end

    test "matches the schema" do
      assert Schema.mismatch(record(), Records.schema()) == nil
    end

    test "holds nil for each fact the client did not supply" do
      connection = %{
        @connection
        | reconnect: nil,
          viewport_width_bucket: nil,
          language: nil,
          referrer_host: nil
      }

      assert %{
               "reconnect" => nil,
               "viewportWidthBucket" => nil,
               "language" => nil,
               "referrerHost" => nil
             } = record(%{connection: connection})
    end

    test "keeps at most 32 values of a field and counts the rest" do
      values = for index <- 1..40, do: Integer.to_string(index)

      assert %{"filter" => %{"route" => kept}, "filterValueOmittedCount" => 8} =
               record(%{filter: %{"route" => values}})

      assert kept == Enum.take(values, 32)
    end

    test "keeps at most four fields, in field order, and counts the values of the rest" do
      filter = Map.new(["e", "a", "c", "b", "d"], &{&1, ["x", "y"]})

      assert %{"filter" => kept, "filterValueOmittedCount" => 2} = record(%{filter: filter})
      assert Map.keys(kept) == ["a", "b", "c", "d"]
    end

    test "leaves out a value longer than 64 bytes and counts it" do
      long = String.duplicate("x", 65)

      assert %{"filter" => %{"agency" => ["1"]}, "filterValueOmittedCount" => 1} =
               record(%{filter: %{"agency" => [long, "1"]}})
    end

    for {label, changes} <- [
          {"a negative duration", %{duration_ms: -1}},
          {"an empty page", %{connection: Map.put(@connection, :page, "")}},
          {"a page longer than 32 bytes",
           %{connection: Map.put(@connection, :page, String.duplicate("p", 33))}},
          {"a device class that is no text",
           %{connection: Map.put(@connection, :device_class, nil)}},
          {"a reconnect that is no boolean", %{connection: Map.put(@connection, :reconnect, 1)}}
        ] do
      test "refuses #{label}" do
        assert_raise AssertionError, fn -> record(unquote(Macro.escape(changes))) end
      end
    end
  end

  describe "file/1" do
    @written_at ~U[2026-10-08 23:59:30Z]

    defp file(records) do
      Records.file(%{records: records, written_at: @written_at, file_id: "0199c4a2-7e1b"})
    end

    test "names a compressed destination under the date written" do
      %{destination: destination} = file([record()])

      assert destination == "usage/page-connections/dt=2026-10-08/0199c4a2-7e1b.json.gz"
      assert {:ok, _segments} = Destination.validate(destination)
      assert Compression.compressed?(destination)
    end

    test "holds the records in order, with their count and the time written" do
      first = record()
      second = record(%{duration_ms: 5})

      assert %{content: content} = file([first, second])

      assert JSON.decode!(content) == %{
               "meta" => %{
                 "recordCount" => 2,
                 "schemaVersion" => 1,
                 "writtenAt" => "2026-10-08T23:59:30Z"
               },
               "records" => [first, second]
             }
    end

    test "refuses a record outside the schema" do
      assert_raise AssertionError, fn -> file([Map.delete(record(), "page")]) end
    end

    test "refuses more records than a file holds" do
      records = List.duplicate(record(), Records.file_record_count_max() + 1)

      assert_raise AssertionError, fn -> file(records) end
    end
  end
end
