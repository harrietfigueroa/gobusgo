defmodule Gobusgo.OneBusAway.RoutePaths do
  @moduledoc """
  Requester for the stops and the travel paths of one route
  (`stops-for-route`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.RoutePaths.fetch_response(settings, route_id: "40_100479") do
        {:ok, response} -> response.route_path.polylines
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, response}`, where `response` holds the `:route_id` asked for, the
  `:route_path` as a `t:route_path/0`, the whole decoded `:envelope`, the
  `:http_status`, the `:method` and `:host` of the request, and
  `:fetched_at`, the UTC time the response arrived. The API key is replaced
  wherever the server echoes it, and the host carries no credentials.

  Errors are those of `Gobusgo.OneBusAway.Client.get/3` and
  `Gobusgo.OneBusAway.Envelope.interpret/2`; a route the server does not
  know is `{:http_status, 404}`.

  Options: `:route_id` (required), `:clock`, a zero-arity function returning
  the current UTC `DateTime`, and those of `Gobusgo.OneBusAway.Client.get/3`
  other than `:params`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/stops-for-route — checked 2026-10-05
  @path_prefix "/api/where/stops-for-route/"
  @path_suffix ".json"
  @method "GET"
  @params [includePolylines: "true"]

  @stop_count_max 1_000
  @polyline_count_max 1_000
  @stop_grouping_count_max 8
  @stop_group_count_max 16

  # The characters of the encoded polyline format: each is a five-bit chunk
  # plus 63, with 32 added to every chunk but a number's last
  # (https://developers.google.com/maps/documentation/utilities/polylinealgorithm
  # — checked 2026-10-05).
  @points_pattern ~r/\A[?-~]+\z/

  @typedoc """
  One line of a path. `points` is the line in the encoded polyline format,
  at five decimal places, and `point_count` is the number of points it
  encodes. `levels` is `nil` when the source sends it empty.
  """
  @type polyline :: %{
          points: String.t(),
          point_count: pos_integer(),
          levels: String.t() | nil
        }

  @typedoc """
  The stops of a route that share one member of a grouping, such as a
  direction of travel, in the grouping's order, with the path that serves
  them. `name` is `nil` when the source sends it empty, and `names` holds
  the names the source supplies, none for such a group.
  """
  @type stop_group :: %{
          id: String.t(),
          name: String.t() | nil,
          names: [String.t()],
          name_type: String.t(),
          stop_ids: [String.t()],
          polylines: [polyline()]
        }

  @type stop_grouping :: %{
          type: String.t(),
          ordered: boolean(),
          stop_groups: [stop_group()]
        }

  @typedoc """
  A stop the route serves. `code`, `direction`, and `parent` are `nil` when
  the source sends them empty.
  """
  @type stop :: %{
          id: String.t(),
          name: String.t(),
          lat: number(),
          lon: number(),
          code: String.t() | nil,
          direction: String.t() | nil,
          location_type: integer(),
          parent: String.t() | nil,
          wheelchair_boarding: String.t(),
          route_ids: [String.t()]
        }

  @typedoc """
  The stops and the paths of one route. `stop_ids` lists every stop of the
  route once, and each stop group lists a part of them. `polylines` is the
  whole route with a stretch that several groups share held once, and each
  group's polylines are that group's own path. `stops` holds the stop of
  every identifier in `stop_ids`. `parent_stops` holds, once and in
  identifier order, each stop outside `stop_ids` that a stop names as its
  `parent` and the response references, so a `parent` can also name a stop
  that neither list holds.
  """
  @type route_path :: %{
          route_id: String.t(),
          stop_ids: [String.t()],
          polylines: [polyline()],
          stop_groupings: [stop_grouping()],
          stops: [stop()],
          parent_stops: [stop()]
        }

  @type response :: %{
          route_id: String.t(),
          route_path: route_path(),
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:route_mismatch, String.t()}
          | {:stop_count_exceeded, pos_integer()}
          | {:stop_grouping_count_exceeded, pos_integer()}
          | {:stop_group_count_exceeded, pos_integer()}
          | {:polyline_count_exceeded, pos_integer()}
          | {:invalid_polyline, polyline()}
          | {:duplicate_stop, String.t()}
          | {:unlisted_stop, String.t()}
          | {:unreferenced_stop, String.t()}

  @polyline_schema {:map, %{"points" => :string, "length" => :integer, "levels" => :string}}

  # The Puget Sound server sends every field below for every route, a list
  # empty where the route has nothing and a string empty where the agency
  # supplies nothing (observed in the responses of all 391 routes,
  # 2026-10-05). A group with an empty name lists `null` as its one name. A
  # group's `subGroups` was always empty and is not read.
  @stop_group_schema {:map,
                      %{
                        "id" => :string,
                        "name" =>
                          {:map,
                           %{
                             "name" => :string,
                             "names" => {:list, {:nullable, :string}},
                             "type" => :string
                           }},
                        "stopIds" => {:list, :string},
                        "polylines" => {:list, @polyline_schema}
                      }}

  @stop_schema {:map,
                %{
                  "id" => :string,
                  "name" => :string,
                  "lat" => :number,
                  "lon" => :number,
                  "code" => :string,
                  "direction" => :string,
                  "locationType" => :integer,
                  "parent" => :string,
                  "wheelchairBoarding" => :string,
                  "routeIds" => {:list, :string}
                }}

  @data_schema {:map,
                %{
                  "entry" =>
                    {:map,
                     %{
                       "routeId" => :string,
                       "stopIds" => {:list, :string},
                       "polylines" => {:list, @polyline_schema},
                       "stopGroupings" =>
                         {:list,
                          {:map,
                           %{
                             "type" => :string,
                             "ordered" => :boolean,
                             "stopGroups" => {:list, @stop_group_schema}
                           }}}
                     }},
                  "references" => {:map, %{"stops" => {:list, @stop_schema}}}
                }}

  @doc """
  Fetches the stops and the paths of one route and returns them together
  with the decoded envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {route_id, options} = Keyword.pop!(options, :route_id)
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")
    Assert.condition(Keyword.get(client_options, :params) == nil, "params are the requester's")
    client_options = Keyword.put(client_options, :params, @params)

    case Client.get(settings, path(route_id), client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()

        with {:ok, envelope} <- Envelope.interpret(client_response, api_key) do
          {:ok,
           %{
             route_id: route_id,
             route_path: parse_data(envelope["data"], route_id),
             envelope: envelope,
             fetched_at: fetched_at,
             host: Client.host(settings),
             http_status: status,
             method: @method
           }}
        end

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp path(route_id) do
    @path_prefix <> URI.encode(route_id, &URI.char_unreserved?/1) <> @path_suffix
  end

  @doc """
  Returns the stops and the paths in `data`, the `data` member of a decoded
  envelope fetched for `route_id`, or the first way `data` breaks the
  contract the live server keeps. A field the source sends empty is `nil`.
  Pure.
  """
  @spec parse(term(), String.t()) :: {:ok, route_path()} | {:error, parse_error()}
  def parse(data, route_id) when is_binary(route_id) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_entry(data["entry"], data["references"]["stops"], route_id)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_entry(%{"routeId" => entry_route_id} = entry, stops, route_id) do
    if entry_route_id == route_id do
      route_path = route_path(entry, stops)

      with :ok <- check_counts(route_path),
           :ok <- check_polylines(route_path),
           :ok <- check_stops(route_path) do
        {:ok, route_path}
      end
    else
      {:error, {:route_mismatch, entry_route_id}}
    end
  end

  defp check_counts(%{stop_ids: stop_ids, stop_groupings: stop_groupings} = route_path) do
    stop_groups = stop_groups(route_path)

    exceeded =
      Enum.find(
        [
          {:stop_count_exceeded, length(stop_ids), @stop_count_max},
          {:stop_grouping_count_exceeded, length(stop_groupings), @stop_grouping_count_max},
          {:stop_group_count_exceeded, length(stop_groups), @stop_group_count_max},
          {:polyline_count_exceeded, length(polylines(route_path)), @polyline_count_max}
        ],
        fn {_reason, count, count_max} -> count > count_max end
      )

    case exceeded do
      nil -> :ok
      {reason, count, _count_max} -> {:error, {reason, count}}
    end
  end

  defp check_polylines(route_path) do
    case Enum.find(polylines(route_path), &(not valid_polyline?(&1))) do
      nil -> :ok
      polyline -> {:error, {:invalid_polyline, polyline}}
    end
  end

  # The rules the schema cannot express: a line has at least one point, and
  # its text holds only the characters the encoding produces.
  defp valid_polyline?(%{points: points, point_count: point_count}) do
    if point_count >= 1 do
      Regex.match?(@points_pattern, points)
    else
      false
    end
  end

  defp check_stops(%{stop_ids: stop_ids, stops: stops} = route_path) do
    listed = MapSet.new(stop_ids)
    referenced = MapSet.new(stops, & &1.id)
    group_stop_ids = Enum.flat_map(stop_groups(route_path), & &1.stop_ids)

    cond do
      duplicate = first_duplicate(stop_ids) -> {:error, {:duplicate_stop, duplicate}}
      unlisted = first_outside(group_stop_ids, listed) -> {:error, {:unlisted_stop, unlisted}}
      missing = first_outside(stop_ids, referenced) -> {:error, {:unreferenced_stop, missing}}
      true -> :ok
    end
  end

  defp first_duplicate(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.find_value(fn {id, count} -> if count > 1, do: id end)
  end

  defp first_outside(ids, set), do: Enum.find(ids, &(not MapSet.member?(set, &1)))

  defp stop_groups(%{stop_groupings: stop_groupings}) do
    Enum.flat_map(stop_groupings, & &1.stop_groups)
  end

  # Every line of the route: its own, then each group's.
  defp polylines(%{polylines: polylines} = route_path) do
    polylines ++ Enum.flat_map(stop_groups(route_path), & &1.polylines)
  end

  defp route_path(entry, references) do
    references_by_id = Map.new(references, &{&1["id"], &1})
    stops = referenced_stops(Enum.uniq(entry["stopIds"]), references_by_id)

    %{
      route_id: entry["routeId"],
      stop_ids: entry["stopIds"],
      polylines: Enum.map(entry["polylines"], &polyline/1),
      stop_groupings: Enum.map(entry["stopGroupings"], &stop_grouping/1),
      stops: stops,
      parent_stops: referenced_stops(parent_ids(stops, entry["stopIds"]), references_by_id)
    }
  end

  defp referenced_stops(ids, references_by_id) do
    ids
    |> Enum.flat_map(&List.wrap(references_by_id[&1]))
    |> Enum.map(&stop/1)
  end

  defp parent_ids(stops, stop_ids) do
    listed = MapSet.new(stop_ids)

    stops
    |> Enum.flat_map(&List.wrap(&1.parent))
    |> Enum.reject(&MapSet.member?(listed, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp polyline(%{"points" => points, "length" => point_count, "levels" => levels}) do
    %{points: points, point_count: point_count, levels: supplied(levels)}
  end

  defp stop_grouping(%{"type" => type, "ordered" => ordered, "stopGroups" => stop_groups}) do
    %{type: type, ordered: ordered, stop_groups: Enum.map(stop_groups, &stop_group/1)}
  end

  defp stop_group(%{"id" => id, "name" => name, "stopIds" => stop_ids, "polylines" => polylines}) do
    %{
      id: id,
      name: supplied(name["name"]),
      names: Enum.reject(name["names"], &is_nil/1),
      name_type: name["type"],
      stop_ids: stop_ids,
      polylines: Enum.map(polylines, &polyline/1)
    }
  end

  defp stop(%{"id" => id, "name" => name, "lat" => lat, "lon" => lon} = stop) do
    %{
      id: id,
      name: name,
      lat: lat,
      lon: lon,
      code: supplied(stop["code"]),
      direction: supplied(stop["direction"]),
      location_type: stop["locationType"],
      parent: supplied(stop["parent"]),
      wheelchair_boarding: stop["wheelchairBoarding"],
      route_ids: stop["routeIds"]
    }
  end

  defp supplied(""), do: nil
  defp supplied(value) when is_binary(value), do: value

  defp parse_data(data, route_id) do
    case parse(data, route_id) do
      {:ok, route_path} ->
        route_path

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, reason} ->
        raise Assert.AssertionError, message: parse_error_message(reason)
    end
  end

  defp parse_error_message({:route_mismatch, entry_route_id}),
    do: "response is for route #{inspect(entry_route_id)}, another than the one asked for"

  defp parse_error_message({:stop_count_exceeded, count}),
    do: "stop count #{count} exceeds #{@stop_count_max}"

  defp parse_error_message({:stop_grouping_count_exceeded, count}),
    do: "stop grouping count #{count} exceeds #{@stop_grouping_count_max}"

  defp parse_error_message({:stop_group_count_exceeded, count}),
    do: "stop group count #{count} exceeds #{@stop_group_count_max}"

  defp parse_error_message({:polyline_count_exceeded, count}),
    do: "polyline count #{count} exceeds #{@polyline_count_max}"

  defp parse_error_message({:invalid_polyline, %{points: points, point_count: point_count}}),
    do: "polyline of #{point_count} points and #{byte_size(points)} bytes is malformed"

  defp parse_error_message({:duplicate_stop, id}), do: "stop identifier #{inspect(id)} repeats"

  defp parse_error_message({:unlisted_stop, id}),
    do: "stop #{inspect(id)} of a group is not among the route's stops"

  defp parse_error_message({:unreferenced_stop, id}), do: "stop #{inspect(id)} has no reference"
end
