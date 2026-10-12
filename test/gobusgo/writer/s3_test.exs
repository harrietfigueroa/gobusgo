defmodule Gobusgo.Writer.S3Test do
  # Writes through the S3 backend against a bucket held in memory and
  # observes what the bucket holds afterwards and what the write returns
  # for each status S3 documents: one behavior per test.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.FakeS3
  alias Gobusgo.Writer
  alias Gobusgo.Writer.S3

  @destination "raw/oba/dt=2026-10-02/response.json"

  setup do
    %{bucket: FakeS3.start()}
  end

  defp write(bucket, destination, content, prefix \\ "") do
    Writer.write(
      %{destination: destination, content: content},
      [backend: S3] ++ FakeS3.options(bucket, prefix)
    )
  end

  test "stores the content under the destination", %{bucket: bucket} do
    assert write(bucket, @destination, "content") == :ok

    assert FakeS3.get(bucket, @destination) == "content"
  end

  test "stores under the key prefix", %{bucket: bucket} do
    write(bucket, @destination, "content", "gobusgo/production/")

    assert FakeS3.keys(bucket) == ["gobusgo/production/" <> @destination]
  end

  test "stores a compressed destination as one gzip stream", %{bucket: bucket} do
    write(bucket, @destination <> ".gz", "content")

    assert :zlib.gunzip(FakeS3.get(bucket, @destination <> ".gz")) == "content"
  end

  test "answers already exists for a destination that holds content", %{bucket: bucket} do
    write(bucket, @destination, "first")

    assert write(bucket, @destination, "second") == {:error, :already_exists}
  end

  test "leaves the content of a destination that holds some", %{bucket: bucket} do
    write(bucket, @destination, "first")
    write(bucket, @destination, "second")

    assert FakeS3.get(bucket, @destination) == "first"
  end

  test "refuses content past the size limit and sends nothing", %{bucket: bucket} do
    content = :binary.copy("a", S3.content_bytes_max() + 1)

    assert write(bucket, @destination, content) == {:error, :content_too_large}
    assert FakeS3.requests(bucket) == []
  end

  for {destination, reason} <- [
        {"../a", :traversal},
        {"/a", :absolute},
        {".hidden", :segment_invalid},
        {"a b", :segment_invalid}
      ] do
    test "refuses the destination #{destination} as #{reason}", %{bucket: bucket} do
      assert write(bucket, unquote(destination), "x") ==
               {:error, {:invalid_destination, unquote(reason)}}

      assert FakeS3.requests(bucket) == []
    end
  end

  test "answers permission denied for status 403", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [403])

    assert write(bucket, @destination, "x") == {:error, :permission_denied}
  end

  for status <- [404, 500, 503] do
    test "answers io failure for status #{status}", %{bucket: bucket} do
      FakeS3.answer_next(bucket, List.duplicate(unquote(status), 3))

      assert write(bucket, @destination, "x") == {:error, :io_failure}
    end
  end

  test "stores after a conflict with a request in flight", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [409])

    assert write(bucket, @destination, "content") == :ok
    assert FakeS3.get(bucket, @destination) == "content"
  end

  test "raises for a status S3 does not document for a write", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [418])

    assert_raise Gobusgo.Assert.AssertionError, fn -> write(bucket, @destination, "x") end
  end
end
