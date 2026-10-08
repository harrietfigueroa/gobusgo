defmodule Gobusgo.OneBusAway.Readiness do
  @moduledoc """
  Whether the views hold what a start fills them with, so that the node can
  serve pages in place of one that has run for a day.

  The node is ready once the agency view has a current fetch and every route
  item of its agencies, as `Gobusgo.OneBusAway.RouteItems` reads them, has a
  fetch attempt. An attempt whose response did not reach its view counts: the
  route source fetches that item again when its slot comes, and no sooner.
  An item that is due because its slot has come has an attempt, so the daily
  refresh of a full view leaves the node ready.

  A read reads the views' tables. It calls no process and starts no fetch.

  ## Options

    * `:agency_fetch`: a zero-arity function returning the agency view's
      current fetch, or `nil` when it has none. Defaults to the current fetch
      of `Gobusgo.OneBusAway.AgencyView`.
    * `:route_view` and `:route_path_view`: the fetch views read. Default to
      `Gobusgo.OneBusAway.RouteView` and `Gobusgo.OneBusAway.RoutePathView`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.RouteItems

  @typedoc """
  Why the node is still filling: the agency view has no fetch, or
  `{:route_items_unattempted, count}`, the count of route items that have no
  fetch attempt, which is one or more.
  """
  @type gap :: :agency_fetch_absent | {:route_items_unattempted, pos_integer()}

  @doc "Returns `:ready`, or `{:filling, gap}` with the first gap found."
  @spec read(Keyword.t()) :: :ready | {:filling, gap()}
  def read(options) when is_list(options) do
    options =
      Keyword.validate!(options,
        agency_fetch: &current_agency_fetch/0,
        route_view: Gobusgo.OneBusAway.RouteView,
        route_path_view: Gobusgo.OneBusAway.RoutePathView
      )

    case Keyword.fetch!(options, :agency_fetch).() do
      nil ->
        {:filling, :agency_fetch_absent}

      %{agency_ids: agency_ids} ->
        attempts =
          RouteItems.read(%{
            agency_ids: agency_ids,
            route_view: Keyword.fetch!(options, :route_view),
            route_path_view: Keyword.fetch!(options, :route_path_view)
          })

        Assert.condition(
          length(attempts) >= length(agency_ids),
          "every agency must have an item, got: #{length(attempts)} for #{length(agency_ids)}"
        )

        case Enum.count(attempts, &(&1.attempted_at == nil)) do
          0 -> :ready
          unattempted_count -> {:filling, {:route_items_unattempted, unattempted_count}}
        end
    end
  end

  defp current_agency_fetch, do: AgencyView.current(AgencyView)
end
