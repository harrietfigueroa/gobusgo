defmodule Gobusgo.Routing.Snapshots.Walk do
  @heap_words_max 8_000_000

  @moduledoc """
  How the walks of a set of snapshots are measured, decided once from the
  configured walk basis and the walk graph.

  The plan is one of:

    * `%{kind: :straight, key: key}`: the straight-line rule, because it is
      configured, or because no graph is published.
    * `%{kind: :streets, build_id: build_id, table: binary, key: key}`: the
      streets of the graph build `build_id`, with the packed table of
      links.
    * `%{kind: :mixed, build_id: build_id, table: binary, straight: ids, key: key}`:
      the streets of the graph build `build_id` for the stops the packed table
      measured at their present position, and the straight line for the stops
      `ids` and every link to one. It stands in for a table that is not
      current.
    * `%{kind: :unavailable, build_id: build_id, stale: stale}`: the streets are
      configured and a graph is published, and its links are not measured yet
      or cannot be, or its manifest cannot be read (`build_id` is then `nil`).
      A date with an entry keeps it, and one without is built by `fallback/2`.

  `key` is part of a date's inputs, so a date is built again when the basis,
  the graph build, or the table changes. With the straight line configured
  nothing here reads a file or starts a process.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Config
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Routing.WalkLinks.Store

  @type t ::
          %{kind: :straight, key: term()}
          | %{kind: :streets, build_id: String.t(), table: binary(), key: term()}
          | %{
              kind: :mixed,
              build_id: String.t(),
              table: binary(),
              straight: MapSet.t(String.t()),
              key: term()
            }
          | %{
              required(:kind) => :unavailable,
              required(:build_id) => String.t() | nil,
              optional(:measure) => Gobusgo.Routing.Snapshots.walk_links_request(),
              required(:stale) => %{table: binary(), build_id: String.t()} | nil
            }

  @doc "The heap cap, in words, of the process that measures the links."
  @spec heap_words_max() :: pos_integer()
  def heap_words_max, do: @heap_words_max

  @doc """
  The milliseconds the process that measures the links has: the time between
  two runs of the build less the time a run has, so a measuring, which a run
  starts as it ends, is over, with the grace it is killed after, before the next
  run starts.
  """
  @spec deadline_ms() :: pos_integer()
  def deadline_ms do
    deadline_ms = Snapshots.check_interval_ms() - Snapshots.run_deadline_ms()

    Assert.condition(
      deadline_ms + Snapshots.deadline_grace_ms() <= Snapshots.check_interval_ms(),
      "a measuring of #{deadline_ms} ms and its grace outlast the interval between runs"
    )

    deadline_ms
  end

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

  def links(%{kind: :mixed, table: table, straight: straight}, stop_ids, positions) do
    WalkLinks.mixed_links(%{
      stop_ids: stop_ids,
      positions: positions,
      table: WalkLinks.unpack(table),
      straight_ids: straight
    })
  end

  @doc """
  What the manifest entry says of how its walks were measured: `:mixed` where
  some stops' links are the straight line and the rest are the streets of the
  build, so the entry does not claim the streets for links that are not.
  """
  @spec entry_basis(t()) :: %{kind: :straight | :streets | :mixed, build_id: String.t() | nil}
  def entry_basis(%{kind: :mixed, build_id: build_id}), do: %{kind: :mixed, build_id: build_id}

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

        %{
          kind: :unavailable,
          build_id: nil,
          stale: Snapshots.walk_table(Keyword.fetch!(options, :server))
        }

      {:ok, manifest} ->
        request = %{
          manifest: manifest,
          positions: positions,
          read_options: read_options,
          heap_words_max: Keyword.fetch!(options, :walk_heap_words_max),
          deadline_ms: Keyword.fetch!(options, :walk_deadline_ms),
          deadline_grace_ms: Snapshots.deadline_grace_ms()
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
    %{
      kind: :unavailable,
      build_id: request.manifest.build_id,
      measure: request,
      stale: Snapshots.walk_table(server)
    }
  end

  defp answer(_pending_or_failed, request, server) do
    %{
      kind: :unavailable,
      build_id: request.manifest.build_id,
      stale: Snapshots.walk_table(server)
    }
  end

  @doc """
  The plan a date is built by where `plan` is unavailable. The last table held
  stands in only on the graph build the manifest names now: its stops that
  have an entry at their present position keep its street links, and the stops
  it has no measure of, a new stop or a moved one, have the straight line, as
  do the links to them. A table of another build, or a manifest that was not
  read, has no stand-in, and the straight line builds every stop.
  """
  @spec fallback(t(), WalkLinks.positions()) :: t()
  def fallback(
        %{kind: :unavailable, build_id: build_id, stale: %{build_id: build_id} = stale},
        positions
      )
      when is_binary(build_id) do
    table = WalkLinks.unpack(stale.table)
    straight = WalkLinks.unmeasured_stop_ids(%{positions: positions, table: table})
    held_sha256 = :crypto.hash(:sha256, stale.table)

    if MapSet.size(straight) == 0 do
      %{
        kind: :streets,
        build_id: build_id,
        table: stale.table,
        key: {:streets, build_id, held_sha256}
      }
    else
      straight_sha256 = :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(straight)))

      %{
        kind: :mixed,
        build_id: build_id,
        table: stale.table,
        straight: straight,
        key: {:mixed, build_id, held_sha256, straight_sha256}
      }
    end
  end

  def fallback(%{kind: :unavailable}, _positions) do
    %{kind: :straight, key: {:straight, :unavailable}}
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
