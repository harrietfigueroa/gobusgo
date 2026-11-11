defmodule GobusgoWeb.Mcp.AnswerCacheTest do
  # Checks what the cache answers for a key, counting computations through
  # an Agent the test owns, which is the test's own bookkeeping and not a
  # spy on the cache. The cache is the application's, under its own name,
  # so the cases do not run beside each other.
  use ExUnit.Case, async: false

  alias GobusgoWeb.Mcp.AnswerCache

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %{counter: counter}
  end

  # An answer computation that returns how many answers it has computed.
  defp compute(counter) do
    fn -> Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end) end
  end

  defp unique_key, do: {:answer_cache_test, System.unique_integer([:positive])}

  test "computes an answer once for a key", %{counter: counter} do
    key = unique_key()

    assert AnswerCache.fetch(key, compute(counter)) == 1
    assert AnswerCache.fetch(key, compute(counter)) == 1
  end

  test "computes an answer for each key", %{counter: counter} do
    assert AnswerCache.fetch(unique_key(), compute(counter)) == 1
    assert AnswerCache.fetch(unique_key(), compute(counter)) == 2
  end

  test "finds no answer under the key of a newer fetch", %{counter: counter} do
    older = {:answer_cache_test, :stop, "fetch-1"}
    newer = {:answer_cache_test, :stop, "fetch-2"}

    assert AnswerCache.fetch(older, compute(counter)) == 1
    assert AnswerCache.fetch(newer, compute(counter)) == 2
  end

  test "holds no more answers than its bound", %{counter: counter} do
    for _index <- 1..(AnswerCache.entry_count_max() * 2) do
      AnswerCache.fetch(unique_key(), compute(counter))
    end

    assert AnswerCache.entry_count() <= AnswerCache.entry_count_max()
  end
end
