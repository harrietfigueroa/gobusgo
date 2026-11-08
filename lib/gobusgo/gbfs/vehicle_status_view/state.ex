defmodule Gobusgo.Gbfs.VehicleStatusView.State do
  @moduledoc """
  The rules of the shared vehicle view: which entry is current for each
  system. Everything here is pure.

  An entry is a fetch, or a finding that the system's feed is not published,
  and each carries the time of its fetch and its request identifier. An
  entry is current as soon as it is put. An entry is ignored when it is its
  system's current one or is older than it, so records published again
  change nothing and an old fetch never replaces a newer one; an entry with
  the same time as the current one and another request identifier replaces
  it. A newer finding that the feed is not published replaces a fetch, which
  leaves the system with no vehicles.

  At most `system_count_max` systems have an entry; the entry of a system
  beyond that is ignored. The state keeps the request identifier, the time,
  and the kind of each current entry, which is all its rules read.
  """

  alias Gobusgo.Assert
  alias Gobusgo.RequestId

  @typedoc "What an entry has to carry for the rules; the view holds the rest."
  @type entry :: %{
          required(:kind) => :fetched | :not_published,
          required(:id) => String.t(),
          required(:request_id) => RequestId.t(),
          required(:fetched_at) => DateTime.t(),
          optional(atom()) => term()
        }

  @type header :: %{
          kind: :fetched | :not_published,
          request_id: RequestId.t(),
          fetched_at: DateTime.t()
        }

  @type t :: %{current: %{String.t() => header()}, system_count_max: pos_integer()}

  @typedoc """
    * `:switched` — the entry is now its system's current one.
    * `:ignored` — the entry changed nothing.
  """
  @type outcome :: :switched | :ignored

  @doc "A view with no entry, for at most `system_count_max` systems."
  @spec new(pos_integer()) :: t()
  def new(system_count_max) when is_integer(system_count_max) do
    Assert.condition(system_count_max >= 1, "system_count_max must be positive")
    %{current: %{}, system_count_max: system_count_max}
  end

  @doc "Puts `entry` and returns whether it became its system's current entry."
  @spec put(t(), entry()) :: {t(), outcome()}
  def put(state, %{kind: kind, id: id, request_id: request_id, fetched_at: %DateTime{}} = entry)
      when kind in [:fetched, :not_published] and is_binary(id) do
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    header = %{kind: kind, request_id: request_id, fetched_at: entry.fetched_at}

    case Map.fetch(state.current, id) do
      {:ok, current} ->
        if newer?(header, current) do
          {%{state | current: Map.put(state.current, id, header)}, :switched}
        else
          {state, :ignored}
        end

      :error ->
        if map_size(state.current) < state.system_count_max do
          {%{state | current: Map.put(state.current, id, header)}, :switched}
        else
          {state, :ignored}
        end
    end
  end

  defp newer?(header, current) do
    case DateTime.compare(header.fetched_at, current.fetched_at) do
      :gt -> true
      :eq -> header.request_id != current.request_id
      :lt -> false
    end
  end
end
