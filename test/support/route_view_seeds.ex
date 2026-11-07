defmodule Gobusgo.Test.RouteViewSeeds do
  @moduledoc """
  Fills the two route fetch views for a test, with records built the way the
  route processors build them, so a test states which agencies list which
  routes and which routes have a path, and nothing else of a fetch.
  """

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @data_sha256 String.duplicate("ab", 32)

  @doc "Gives `view` a fetch, made at `fetched_at`, of the routes `route_ids` of `agency_id`."
  @spec routes(atom(), %{
          agency_id: String.t(),
          route_ids: [String.t()],
          fetched_at: DateTime.t()
        }) :: :ok
  def routes(view, %{agency_id: agency_id, route_ids: route_ids, fetched_at: fetched_at}) do
    colored = for route_id <- route_ids, do: {route_id, nil}
    colored_routes(view, %{agency_id: agency_id, routes: colored, fetched_at: fetched_at})
  end

  @doc """
  Gives `view` a fetch, made at `fetched_at`, of the routes of `agency_id`
  that `routes` names in order, each with its color: six hexadecimal digits
  or `nil`.
  """
  @spec colored_routes(atom(), %{
          agency_id: String.t(),
          routes: [{String.t(), String.t() | nil}],
          fetched_at: DateTime.t()
        }) :: :ok
  def colored_routes(view, %{agency_id: agency_id, routes: routes, fetched_at: fetched_at}) do
    record =
      RouteBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/routes-for-agency/seeded.json.gz",
        fetched_at: fetched_at,
        data_sha256: @data_sha256,
        request_id: @request_id,
        routes:
          for {id, color} <- routes do
            %{
              id: id,
              agency_id: agency_id,
              short_name: nil,
              long_name: nil,
              description: nil,
              type: 3,
              color: color,
              text_color: nil,
              url: nil
            }
          end
      })

    :ok = FetchView.apply_records(view, [record.value])
  end

  @doc "Gives `view` a fetch, made at `fetched_at`, of the stops and paths of `route_id`, all empty."
  @spec route_path(atom(), %{route_id: String.t(), fetched_at: DateTime.t()}) :: :ok
  def route_path(view, %{route_id: route_id, fetched_at: fetched_at}) do
    record =
      RoutePathBatch.Records.build(%{
        route_id: route_id,
        destination: "raw/oba/stops-for-route/seeded.json.gz",
        fetched_at: fetched_at,
        data_sha256: @data_sha256,
        request_id: @request_id,
        route_path: %{
          route_id: route_id,
          stop_ids: [],
          polylines: [],
          stop_groupings: [],
          stops: []
        }
      })

    :ok = FetchView.apply_records(view, [record.value])
  end
end
