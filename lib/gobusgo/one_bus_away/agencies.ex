defmodule Gobusgo.OneBusAway.Agencies do
  @moduledoc """
  Requester for OneBusAway agency discovery (`agencies-with-coverage`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Setup

  Set `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY` (see the README), then
  read them with `Gobusgo.Config.one_bus_away/0`.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.Agencies.fetch(settings, []) do
        {:ok, agencies} -> Enum.map(agencies, & &1.id)
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, [agency]}`, where each agency is a map with `:id`, `:name`, `:url`,
  `:timezone`, and `:coverage` (`:lat`, `:lon`, `:lat_span`, `:lon_span`).
  Every coverage entry is resolved against the response references.

  `fetch_response/2` returns `{:ok, response}` for the same request, where
  `response` adds what the agency list leaves out: the whole decoded
  `:envelope`, the `:http_status`, the `:method` and `:host` of the request,
  and `:fetched_at`, the UTC time the response arrived. The API key is
  replaced wherever the server echoes it, and the host carries no credentials.

  Errors, shared by both functions:

    * `{:transport, reason}`: a network fault such as `:timeout` or `:econnrefused`
    * `:deadline_exceeded`: all attempts together outlasted `:deadline_ms`
    * `:rate_limited`: the request gate granted no permit inside the deadline
    * `{:http_status, status}`: a 4xx or 5xx response
    * `{:unexpected_redirect, status}`: a 3xx response, never followed
    * `{:api_error, %{code: code, text: text}}`: HTTP 200 with a non-200 envelope code
    * `:invalid_json`: the body is not JSON

  Options are those of `Gobusgo.OneBusAway.Client.get/3`, plus `:clock`, a
  zero-arity function returning the current UTC `DateTime`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/agencies-with-coverage — checked 2026-10-01
  @path "/api/where/agencies-with-coverage.json"
  @method "GET"
  @agency_count_max 1_000

  @type coverage :: %{lat: number(), lon: number(), lat_span: number(), lon_span: number()}
  @type agency :: %{
          id: String.t(),
          name: String.t(),
          url: String.t(),
          timezone: String.t(),
          coverage: coverage()
        }
  @type response :: %{
          agencies: [agency()],
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:agency_count_exceeded, pos_integer()}
          | {:unreferenced_agency, String.t()}

  @data_schema {:map,
                %{
                  "limitExceeded" => {:literal, false},
                  "list" =>
                    {:list,
                     {:map,
                      %{
                        "agencyId" => :string,
                        "lat" => :number,
                        "lon" => :number,
                        "latSpan" => :number,
                        "lonSpan" => :number
                      }}},
                  "references" =>
                    {:map,
                     %{
                       "agencies" =>
                         {:list,
                          {:map,
                           %{
                             "id" => :string,
                             "name" => :string,
                             "url" => :string,
                             "timezone" => :string
                           }}}
                     }}
                }}

  @doc "Fetches every agency with coverage from the configured server."
  @spec fetch(Client.settings(), Keyword.t()) :: {:ok, [agency()]} | {:error, error()}
  def fetch(settings, options) when is_list(options) do
    with {:ok, %{agencies: agencies}} <- fetch_response(settings, options) do
      {:ok, agencies}
    end
  end

  @doc """
  Fetches every agency with coverage and returns the agencies together with
  the decoded envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")

    case Client.get(settings, @path, client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()

        with {:ok, envelope} <- Envelope.interpret(client_response, api_key) do
          {:ok,
           %{
             agencies: parse_data(envelope["data"]),
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

  @doc """
  Returns the agencies in `data`, the `data` member of a decoded envelope,
  with every coverage entry resolved against the references, or the first
  way `data` breaks the documented contract. Pure.
  """
  @spec parse(term()) :: {:ok, [agency()]} | {:error, parse_error()}
  def parse(data) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_entries(data)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_entries(%{"list" => entries, "references" => %{"agencies" => references}}) do
    count = length(entries)

    if count <= @agency_count_max do
      references_by_id = Map.new(references, &{&1["id"], &1})
      resolve_entries(entries, references_by_id)
    else
      {:error, {:agency_count_exceeded, count}}
    end
  end

  defp resolve_entries(entries, references_by_id) do
    case Enum.find(entries, &(not is_map_key(references_by_id, &1["agencyId"]))) do
      nil -> {:ok, Enum.map(entries, &resolve(&1, references_by_id))}
      %{"agencyId" => id} -> {:error, {:unreferenced_agency, id}}
    end
  end

  defp resolve(%{"agencyId" => id} = entry, references_by_id) do
    reference = Map.fetch!(references_by_id, id)

    %{
      id: id,
      name: reference["name"],
      url: reference["url"],
      timezone: reference["timezone"],
      coverage: %{
        lat: entry["lat"],
        lon: entry["lon"],
        lat_span: entry["latSpan"],
        lon_span: entry["lonSpan"]
      }
    }
  end

  defp parse_data(data) do
    case parse(data) do
      {:ok, agencies} ->
        agencies

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, {:agency_count_exceeded, count}} ->
        raise Assert.AssertionError,
          message: "agency count #{count} exceeds #{@agency_count_max}"

      {:error, {:unreferenced_agency, id}} ->
        raise Assert.AssertionError,
          message: "list entry #{inspect(id)} has no agency reference"
    end
  end
end
