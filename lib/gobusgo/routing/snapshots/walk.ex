defmodule Gobusgo.Routing.Snapshots.Walk do
  @heap_words_max 48_000_000
  @deadline_ms 600_000

  @moduledoc """
  How one run of `Gobusgo.Routing.Snapshots.Build` measures the walks of the
  snapshots it builds, decided once per run from the configured walk basis
  and the walk graph.

  The plan is one of:

    * `%{kind: :straight, key: key}`: the straight-line rule, because it is
      configured, or because no graph is published.
    * `%{kind: :streets, build_id: build_id, table: binary, key: key}`: the
      streets of the graph build `build_id`, with the packed table of
      links.
    * `%{kind: :unavailable}`: the streets are configured and a graph is
      published, and its links are not measured yet or cannot be, or its
      manifest cannot be read. A date with an entry keeps it, and one without
      is built by the straight line.

  `key` is part of a date's inputs, so a date is built again when the basis,
  the graph build, or the table changes. With the straight line configured
  nothing here reads a file or starts a process.
  """

  require Logger

  alias Gobusgo.Config
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Routing.WalkLinks.Store

  @type t :: %{required(:kind) => :straight | :streets | :unavailable, optional(atom()) => term()}

  @doc "The heap cap, in words, of the process that measures the links."
  @spec heap_words_max() :: pos_integer()
  def heap_words_max, do: @heap_words_max

  @doc "The milliseconds the process that measures the links has."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc """
  The plan for `positions`, the position of each stop by identifier. The
  options are those of `Gobusgo.Routing.Snapshots.Build`: `:walk_basis`
  (`nil` for the configured one), `:walk_read_options`,
  `:walk_heap_words_max`, `:walk_deadline_ms`, and `:server`.
  """
  @spec plan(keyword(), WalkLinks.positions()) :: t()
  def plan(options, positions) do
    case basis(options) do
      :straight -> %{kind: :straight, key: :straight}
      :streets -> streets(options, positions)
    end
  end

  @doc "The walking links of the stops `stop_ids` under `plan`, as the transfers file holds them."
  @spec links(t(), [String.t()], WalkLinks.positions()) :: [map()]
  def links(%{kind: :streets, table: table}, stop_ids, positions) do
    WalkLinks.links(%{stop_ids: stop_ids, positions: positions, table: WalkLinks.unpack(table)})
  end

  def links(%{kind: :straight}, stop_ids, positions) do
    Transfers.walking_links(stop_ids, positions)
  end

  @doc "What the manifest entry says of how its walks were measured."
  @spec entry_basis(t()) :: %{kind: :straight | :streets, build_id: String.t() | nil}
  def entry_basis(%{kind: :streets, build_id: build_id}),
    do: %{kind: :streets, build_id: build_id}

  def entry_basis(%{kind: :straight}), do: %{kind: :straight, build_id: nil}

  defp basis(options) do
    case Keyword.fetch!(options, :walk_basis) do
      nil ->
        {:ok, basis} = Config.walk_basis()
        basis

      basis when basis in [:straight, :streets] ->
        basis
    end
  end

  defp streets(options, positions) do
    read_options = Keyword.fetch!(options, :walk_read_options)

    case Store.manifest(read_options) do
      :none ->
        %{kind: :straight, key: {:straight, :no_graph}}

      {:error, cause} ->
        log_manifest_failure(cause)
        %{kind: :unavailable, stale: Snapshots.walk_table(Keyword.fetch!(options, :server))}

      {:ok, manifest} ->
        request = %{
          manifest: manifest,
          positions: positions,
          read_options: read_options,
          heap_words_max: Keyword.fetch!(options, :walk_heap_words_max),
          deadline_ms: Keyword.fetch!(options, :walk_deadline_ms)
        }

        server = Keyword.fetch!(options, :server)
        answer(Snapshots.walk_links(server, Map.put(request, :start?, false)), request, server)
    end
  end

  defp answer({:ready, %{table: table, build_id: build_id}}, _request, _server) do
    %{
      kind: :streets,
      build_id: build_id,
      table: table,
      key: {:streets, build_id, :crypto.hash(:sha256, table)}
    }
  end

  defp answer(:not_current, request, server) do
    %{kind: :unavailable, measure: request, stale: Snapshots.walk_table(server)}
  end

  defp answer(_pending_or_failed, _request, server) do
    %{kind: :unavailable, stale: Snapshots.walk_table(server)}
  end

  @doc """
  Starts measuring the table of a plan that is not current, once the run's
  dates are built. Anything else of a plan is left as it is.
  """
  @spec measure(t(), keyword()) :: :ok
  def measure(%{kind: :unavailable, measure: request}, options) do
    Snapshots.walk_links(Keyword.fetch!(options, :server), Map.put(request, :start?, true))
    :ok
  end

  def measure(_plan, _options), do: :ok

  defp log_manifest_failure(:corrupt) do
    Logger.error("Routing walk graph manifest not read", cause: :corrupt)
  end

  defp log_manifest_failure({:io, reason}) do
    Logger.warning("Routing walk graph manifest not read", cause: :io, reason: inspect(reason))
  end
end
