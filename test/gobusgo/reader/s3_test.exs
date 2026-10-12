defmodule Gobusgo.Reader.S3Test do
  # Reads and discovers through the S3 backend against a bucket held in
  # memory: one behavior per test, covering reads, discovery order and
  # paging across listing requests, the keys left out, and what each
  # documented status returns.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader
  alias Gobusgo.Reader.S3
  alias Gobusgo.Test.FakeS3

  setup do
    %{bucket: FakeS3.start()}
  end

  defp read(bucket, destination, prefix \\ "") do
    Reader.read(destination, [backend: S3] ++ FakeS3.options(bucket, prefix))
  end

  defp discover(bucket, prefix, overrides \\ []) do
    {options, request} = Keyword.split(overrides, [:page_count_max, :key_prefix])
    {key_prefix, options} = Keyword.pop(options, :key_prefix, "")

    %{prefix: prefix, limit: 100, order: :ascending, cursor: nil}
    |> Map.merge(Map.new(request))
    |> Reader.discover([backend: S3] ++ FakeS3.options(bucket, key_prefix) ++ options)
  end

  defp name(index), do: "raw/" <> String.pad_leading(Integer.to_string(index), 4, "0")

  defp put_many(bucket, count) do
    for index <- 1..count, do: FakeS3.put(bucket, name(index))
  end

  describe "read/2" do
    test "returns the content at the destination", %{bucket: bucket} do
      FakeS3.put(bucket, "raw/dt=2026-10-02/a.json", "{}")

      assert read(bucket, "raw/dt=2026-10-02/a.json") == {:ok, "{}"}
    end

    test "reads under the key prefix", %{bucket: bucket} do
      FakeS3.put(bucket, "gobusgo/a.json", "prefixed")

      assert read(bucket, "a.json", "gobusgo/") == {:ok, "prefixed"}
    end

    test "returns the content a compressed destination holds", %{bucket: bucket} do
      FakeS3.put(bucket, "a.json.gz", :zlib.gzip("content"))

      assert read(bucket, "a.json.gz") == {:ok, "content"}
    end

    test "answers not found for a destination that holds nothing", %{bucket: bucket} do
      assert read(bucket, "absent.json") == {:error, :not_found}
    end

    test "answers permission denied for status 403", %{bucket: bucket} do
      FakeS3.answer_next(bucket, [403])

      assert read(bucket, "a.json") == {:error, :permission_denied}
    end

    test "returns the content after a transient status", %{bucket: bucket} do
      FakeS3.put(bucket, "a.json", "content")
      FakeS3.answer_next(bucket, [503])

      assert read(bucket, "a.json") == {:ok, "content"}
    end

    test "answers io failure when every attempt gets a transient status", %{bucket: bucket} do
      FakeS3.answer_next(bucket, [500, 500, 500])

      assert read(bucket, "a.json") == {:error, :io_failure}
    end

    test "refuses a traversal and sends nothing", %{bucket: bucket} do
      assert read(bucket, "../a") == {:error, {:invalid_destination, :traversal}}
      assert FakeS3.requests(bucket) == []
    end

    test "raises for a status S3 does not document for a read", %{bucket: bucket} do
      FakeS3.answer_next(bucket, [418])

      assert_raise Gobusgo.Assert.AssertionError, fn -> read(bucket, "a.json") end
    end
  end

  describe "discover/2 ascending" do
    test "lists the destinations under the prefix in byte order", %{bucket: bucket} do
      for key <- ["raw/b", "raw/a", "other/c"], do: FakeS3.put(bucket, key)

      assert discover(bucket, "raw/") == {:ok, %{destinations: ["raw/a", "raw/b"], cursor: nil}}
    end

    test "returns an empty page for a prefix that matches nothing", %{bucket: bucket} do
      assert discover(bucket, "raw/") == {:ok, %{destinations: [], cursor: nil}}
    end

    test "lists under the key prefix and returns destinations without it", %{bucket: bucket} do
      for key <- ["gobusgo/raw/a", "raw/outside"], do: FakeS3.put(bucket, key)

      assert discover(bucket, "raw/", key_prefix: "gobusgo/") ==
               {:ok, %{destinations: ["raw/a"], cursor: nil}}
    end

    test "leaves out a key that is no valid destination", %{bucket: bucket} do
      for key <- ["raw/a", "raw/.hidden", "raw/b c"], do: FakeS3.put(bucket, key)

      assert discover(bucket, "raw/") == {:ok, %{destinations: ["raw/a"], cursor: nil}}
    end

    test "returns a cursor when more destinations than the limit exist", %{bucket: bucket} do
      put_many(bucket, 3)

      assert discover(bucket, "raw/", limit: 2) ==
               {:ok, %{destinations: [name(1), name(2)], cursor: name(2)}}
    end

    test "continues after the cursor of the page before", %{bucket: bucket} do
      put_many(bucket, 3)

      assert discover(bucket, "raw/", limit: 2, cursor: name(2)) ==
               {:ok, %{destinations: [name(3)], cursor: nil}}
    end

    test "returns no cursor when the limit is the count that exists", %{bucket: bucket} do
      put_many(bucket, 2)

      assert discover(bucket, "raw/", limit: 2) ==
               {:ok, %{destinations: [name(1), name(2)], cursor: nil}}
    end

    test "fills a page from several listing requests of at most 100 keys", %{bucket: bucket} do
      put_many(bucket, 250)

      assert {:ok, %{destinations: destinations, cursor: nil}} =
               discover(bucket, "raw/", limit: 1000)

      assert destinations == Enum.map(1..250, &name/1)

      assert for({"GET", "/", %{"max-keys" => count}} <- FakeS3.requests(bucket), do: count) ==
               ["100", "100", "100"]
    end

    test "answers discovery too large past its count of listing requests", %{bucket: bucket} do
      put_many(bucket, 250)

      assert discover(bucket, "raw/", limit: 1000, page_count_max: 2) ==
               {:error, :discovery_too_large}
    end

    test "answers invalid cursor for a cursor that is no destination", %{bucket: bucket} do
      assert discover(bucket, "raw/", cursor: "../a") == {:error, :invalid_cursor}
    end

    test "refuses an empty prefix", %{bucket: bucket} do
      assert discover(bucket, "") == {:error, {:invalid_destination, :empty}}
    end

    test "answers permission denied for status 403", %{bucket: bucket} do
      FakeS3.answer_next(bucket, [403])

      assert discover(bucket, "raw/") == {:error, :permission_denied}
    end

    test "answers io failure for a bucket that does not exist", %{bucket: bucket} do
      FakeS3.answer_next(bucket, [404])

      assert discover(bucket, "raw/") == {:error, :io_failure}
    end
  end

  describe "discover/2 descending" do
    test "lists the destinations from the last to the first", %{bucket: bucket} do
      put_many(bucket, 3)

      assert discover(bucket, "raw/", order: :descending) ==
               {:ok, %{destinations: [name(3), name(2), name(1)], cursor: nil}}
    end

    test "returns a cursor when more destinations than the limit exist", %{bucket: bucket} do
      put_many(bucket, 3)

      assert discover(bucket, "raw/", order: :descending, limit: 2) ==
               {:ok, %{destinations: [name(3), name(2)], cursor: name(2)}}
    end

    test "continues before the cursor of the page before", %{bucket: bucket} do
      put_many(bucket, 3)

      assert discover(bucket, "raw/", order: :descending, limit: 2, cursor: name(2)) ==
               {:ok, %{destinations: [name(1)], cursor: nil}}
    end

    test "answers discovery too large for a prefix past its count of listing requests", %{
      bucket: bucket
    } do
      put_many(bucket, 250)

      assert discover(bucket, "raw/", order: :descending, page_count_max: 2) ==
               {:error, :discovery_too_large}
    end
  end
end
