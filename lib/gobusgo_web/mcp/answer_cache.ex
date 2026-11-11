defmodule GobusgoWeb.Mcp.AnswerCache do
  @entry_count_max 256

  @moduledoc """
  The answers the MCP tools hold, each under a key that names the question
  and the identity of the view fetches the answer draws on
  (`GobusgoWeb.TransitQuery`'s `*_version/1`). A newer fetch changes the
  key, so a call finds no answer from before it and a held answer never
  outlives a newer fetch; an entry left under an older key is never read
  again and goes when the cache is cleared.

  The cache holds at most #{@entry_count_max} entries. A miss that finds it
  full clears it first, which keeps the rule one line long where an
  eviction order would take state of its own.

  The process owns a public ETS table that callers read and write
  directly, so a call never waits on the process. Two callers that miss the
  same key compute the answer twice and store the same value.
  """

  use GenServer

  @table __MODULE__

  @doc "The most answers the cache holds."
  @spec entry_count_max() :: pos_integer()
  def entry_count_max, do: @entry_count_max

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(options, [:name]))
  end

  @doc """
  The answer held under `key`, or the result of `compute_callback`, held
  under `key` from then on. Computes without holding while the cache is not
  running.
  """
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, compute_callback) when is_function(compute_callback, 0) do
    case :ets.whereis(@table) do
      :undefined -> compute_callback.()
      table -> fetch_from(table, key, compute_callback)
    end
  end

  @doc "How many answers the cache holds, `0` while it is not running."
  @spec entry_count() :: non_neg_integer()
  def entry_count do
    case :ets.whereis(@table) do
      :undefined -> 0
      table -> :ets.info(table, :size)
    end
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, :no_state}
  end

  defp fetch_from(table, key, compute_callback) do
    case :ets.lookup(table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = compute_callback.()

        if :ets.info(table, :size) >= @entry_count_max do
          :ets.delete_all_objects(table)
        end

        :ets.insert(table, {key, value})
        value
    end
  end
end
