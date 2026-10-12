defmodule Gobusgo.Deleter.S3Test do
  # Deletes through the S3 backend against a bucket held in memory and
  # observes what the bucket holds afterwards and what the deletion returns
  # for each status S3 documents: one behavior per test.
  use ExUnit.Case, async: true

  alias Gobusgo.Deleter
  alias Gobusgo.Deleter.S3
  alias Gobusgo.Test.FakeS3

  @destination "raw/oba/dt=2026-10-02/response.json"

  setup do
    %{bucket: FakeS3.start()}
  end

  defp delete(bucket, destination, prefix \\ "") do
    Deleter.delete(
      %{destination: destination, within: "raw/"},
      [backend: S3] ++ FakeS3.options(bucket, prefix)
    )
  end

  test "removes the content of the destination", %{bucket: bucket} do
    FakeS3.put(bucket, @destination)

    assert delete(bucket, @destination) == :ok
    assert FakeS3.keys(bucket) == []
  end

  test "removes under the key prefix and leaves the other keys", %{bucket: bucket} do
    for key <- ["gobusgo/" <> @destination, @destination], do: FakeS3.put(bucket, key)

    delete(bucket, @destination, "gobusgo/")

    assert FakeS3.keys(bucket) == [@destination]
  end

  test "answers not found for a destination that holds nothing", %{bucket: bucket} do
    assert delete(bucket, @destination) == {:error, :not_found}
  end

  test "answers not found for content deleted already", %{bucket: bucket} do
    FakeS3.put(bucket, @destination)
    delete(bucket, @destination)

    assert delete(bucket, @destination) == {:error, :not_found}
  end

  test "answers permission denied when the object may not be looked up", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [403])

    assert delete(bucket, @destination) == {:error, :permission_denied}
  end

  test "answers permission denied when the object may not be removed", %{bucket: bucket} do
    FakeS3.put(bucket, @destination)
    FakeS3.answer_next(bucket, [200, 403])

    assert delete(bucket, @destination) == {:error, :permission_denied}
    assert FakeS3.keys(bucket) == [@destination]
  end

  test "answers io failure when every attempt gets a transient status", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [503, 503, 503])

    assert delete(bucket, @destination) == {:error, :io_failure}
  end

  test "refuses a traversal and sends nothing", %{bucket: bucket} do
    assert Deleter.delete(
             %{destination: "raw/../a", within: "raw/"},
             [backend: S3] ++ FakeS3.options(bucket)
           ) == {:error, {:invalid_destination, :traversal}}

    assert FakeS3.requests(bucket) == []
  end

  test "raises for a status S3 does not document for a deletion", %{bucket: bucket} do
    FakeS3.answer_next(bucket, [418])

    assert_raise Gobusgo.Assert.AssertionError, fn -> delete(bucket, @destination) end
  end
end
