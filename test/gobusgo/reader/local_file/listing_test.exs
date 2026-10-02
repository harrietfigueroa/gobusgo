defmodule Gobusgo.Reader.LocalFile.ListingTest do
  # Verifies the ordering and cursor rules of one directory's entries as a
  # pure function, with entries built in the test and no file system.
  use ExUnit.Case, async: true

  alias Gobusgo.Reader.LocalFile.Listing

  defp file(destination), do: %{destination: destination, kind: :file}
  defp directory(destination), do: %{destination: destination, kind: :directory}

  defp arrange(entries, order, cursor) do
    entries |> Listing.arrange(%{order: order, cursor: cursor}) |> Enum.map(& &1.destination)
  end

  describe "arrange/2 ordering" do
    test "sorts files ascending by bytes" do
      assert arrange([file("b"), file("a"), file("B")], :ascending, nil) == ["B", "a", "b"]
    end

    test "sorts files descending by bytes" do
      assert arrange([file("b"), file("a"), file("B")], :descending, nil) == ["b", "a", "B"]
    end

    test "places a directory where the destinations below it sort, ascending" do
      entries = [directory("a"), file("a-b"), file("a0")]

      assert arrange(entries, :ascending, nil) == ["a-b", "a", "a0"]
    end

    test "places a directory where the destinations below it sort, descending" do
      entries = [directory("a"), file("a-b"), file("a0")]

      assert arrange(entries, :descending, nil) == ["a0", "a", "a-b"]
    end

    test "returns an empty list for no entries" do
      assert arrange([], :ascending, nil) == []
    end
  end

  describe "arrange/2 with a cursor" do
    test "keeps only files after the cursor when ascending" do
      entries = [file("d/a"), file("d/b"), file("d/c")]

      assert arrange(entries, :ascending, "d/b") == ["d/c"]
    end

    test "keeps only files before the cursor when descending" do
      entries = [file("d/a"), file("d/b"), file("d/c")]

      assert arrange(entries, :descending, "d/b") == ["d/a"]
    end

    test "keeps the directory that holds the cursor" do
      entries = [directory("d/a"), directory("d/b"), directory("d/c")]

      assert arrange(entries, :ascending, "d/b/x") == ["d/b", "d/c"]
    end

    test "keeps the directory that holds the cursor when descending" do
      entries = [directory("d/a"), directory("d/b"), directory("d/c")]

      assert arrange(entries, :descending, "d/b/x") == ["d/b", "d/a"]
    end

    test "drops a directory whose destinations all precede the cursor" do
      assert arrange([directory("a")], :ascending, "a0") == []
    end

    test "drops a directory whose destinations all follow the cursor when descending" do
      assert arrange([directory("a")], :descending, "a-b") == []
    end
  end

  test "arrange/2 raises for an unknown order" do
    # The order is built at runtime so the compiler's type checker accepts
    # the call and the assertion is what rejects it.
    order = String.to_atom("random")

    assert_raise Gobusgo.Assert.AssertionError, fn ->
      Listing.arrange([file("a")], %{order: order, cursor: nil})
    end
  end
end
