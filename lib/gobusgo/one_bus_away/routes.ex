defmodule Gobusgo.OneBusAway.Routes do
  @moduledoc """
  Requester for the routes of one agency (`routes-for-agency`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.Routes.fetch_response(settings, agency_id: "40") do
        {:ok, response} -> Enum.map(response.routes, & &1.id)
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, response}`, where `response` holds the `:agency_id` asked for, the
  `:routes` as `t:route/0` values in response order, the whole decoded
  `:envelope`, the `:http_status`, the `:method` and `:host` of the request,
  and `:fetched_at`, the UTC time the response arrived. The API key is
  replaced wherever the server echoes it, and the host carries no
  credentials.

  Errors are those of `Gobusgo.OneBusAway.Client.get/3` and
  `Gobusgo.OneBusAway.Envelope.interpret/2`.

  Options: `:agency_id` (required), `:clock`, a zero-arity function returning
  the current UTC `DateTime`, and those of `Gobusgo.OneBusAway.Client.get/3`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/routes-for-agency — checked 2026-10-05
  @path_prefix "/api/where/routes-for-agency/"
  @path_suffix ".json"
  @method "GET"
  @route_count_max 1_000

  # A route's fields are those of the GTFS `routes.txt` file
  # (https://developer.onebusaway.org/api/where/elements/route — checked
  # 2026-10-05), whose colors are six hexadecimal digits with no leading `#`
  # (https://gtfs.org/documentation/schedule/reference/ — checked 2026-10-05).
  @color_pattern ~r/\A[0-9A-Fa-f]{6}\z/

  @typedoc """
  One route of an agency. `id` and `agency_id` are non-empty, and `type` is
  the source's route type number. Every other field is `nil` when the source
  sends it empty. `color` and `text_color` are six hexadecimal digits with
  no leading `#`.
  """
  @type route :: %{
          id: String.t(),
          agency_id: String.t(),
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          description: String.t() | nil,
          type: integer(),
          color: String.t() | nil,
          text_color: String.t() | nil,
          url: String.t() | nil
        }
  @type response :: %{
          agency_id: String.t(),
          routes: [route()],
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:route_count_exceeded, pos_integer()}
          | {:invalid_route, non_neg_integer()}
          | {:duplicate_route, String.t()}

  # The Puget Sound server sends every field of every route, as an empty
  # string where the agency supplies none (observed in the 391 routes of all
  # 12 agencies, 2026-10-05).
  @route_schema {:map,
                 %{
                   "id" => :string,
                   "agencyId" => :string,
                   "shortName" => :string,
                   "longName" => :string,
                   "description" => :string,
                   "type" => :integer,
                   "color" => :string,
                   "textColor" => :string,
                   "url" => :string
                 }}

  @data_schema {:map,
                %{
                  "limitExceeded" => {:literal, false},
                  "list" => {:list, @route_schema}
                }}

  @doc """
  Fetches the routes of one agency and returns them together with the decoded
  envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {agency_id, options} = Keyword.pop!(options, :agency_id)
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")

    case Client.get(settings, path(agency_id), client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()

        with {:ok, envelope} <- Envelope.interpret(client_response, api_key) do
          {:ok,
           %{
             agency_id: agency_id,
             routes: parse_data(envelope["data"], agency_id),
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

  defp path(agency_id) do
    @path_prefix <> URI.encode(agency_id, &URI.char_unreserved?/1) <> @path_suffix
  end

  @doc """
  Returns the routes in `data`, the `data` member of a decoded envelope
  fetched for `agency_id`, in response order, or the first way `data` breaks
  the contract the live server keeps. A field the source sends empty is
  `nil`. Pure.
  """
  @spec parse(term(), String.t()) :: {:ok, [route()]} | {:error, parse_error()}
  def parse(data, agency_id) when is_binary(agency_id) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_list(data["list"], agency_id)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_list(list, agency_id) do
    count = length(list)

    if count <= @route_count_max do
      check_routes(list, agency_id)
    else
      {:error, {:route_count_exceeded, count}}
    end
  end

  defp check_routes(list, agency_id) do
    case Enum.find_index(list, &(not valid_route?(&1, agency_id))) do
      nil -> check_identifiers(list)
      index -> {:error, {:invalid_route, index}}
    end
  end

  # The rules the schema cannot express: the identifier is non-empty, the
  # route belongs to the agency asked for, and a color the source supplies
  # is six hexadecimal digits.
  defp valid_route?(%{"id" => id, "agencyId" => route_agency_id} = route, agency_id) do
    cond do
      id == "" -> false
      route_agency_id != agency_id -> false
      not valid_color?(route["color"]) -> false
      true -> valid_color?(route["textColor"])
    end
  end

  defp valid_color?(""), do: true
  defp valid_color?(color), do: Regex.match?(@color_pattern, color)

  defp check_identifiers(list) do
    duplicate =
      list
      |> Enum.frequencies_by(& &1["id"])
      |> Enum.find(fn {_id, count} -> count > 1 end)

    case duplicate do
      nil -> {:ok, Enum.map(list, &route/1)}
      {id, _count} -> {:error, {:duplicate_route, id}}
    end
  end

  defp route(%{"id" => id, "agencyId" => agency_id, "type" => type} = route) do
    %{
      id: id,
      agency_id: agency_id,
      short_name: supplied(route["shortName"]),
      long_name: supplied(route["longName"]),
      description: supplied(route["description"]),
      type: type,
      color: supplied(route["color"]),
      text_color: supplied(route["textColor"]),
      url: supplied(route["url"])
    }
  end

  defp supplied(""), do: nil
  defp supplied(value) when is_binary(value), do: value

  defp parse_data(data, agency_id) do
    case parse(data, agency_id) do
      {:ok, routes} ->
        routes

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, {:route_count_exceeded, count}} ->
        raise Assert.AssertionError,
          message: "route count #{count} exceeds #{@route_count_max}"

      {:error, {:invalid_route, index}} ->
        raise Assert.AssertionError,
          message:
            "route at index #{index} has an empty identifier, another agency, or a malformed color"

      {:error, {:duplicate_route, id}} ->
        raise Assert.AssertionError, message: "route identifier #{inspect(id)} repeats"
    end
  end
end
