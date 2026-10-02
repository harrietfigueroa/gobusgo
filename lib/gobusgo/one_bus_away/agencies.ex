defmodule Gobusgo.OneBusAway.Agencies do
  @moduledoc """
  Requester for OneBusAway agency discovery (`agencies-with-coverage`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns the
  decoded result and writes nothing.

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

  Errors:

    * `{:transport, reason}`: a network fault such as `:timeout` or `:econnrefused`
    * `:deadline_exceeded`: all attempts together outlasted `:deadline_ms`
    * `{:http_status, status}`: a 4xx or 5xx response
    * `{:unexpected_redirect, status}`: a 3xx response, never followed
    * `{:api_error, %{code: code, text: text}}`: HTTP 200 with a non-200 envelope code
    * `:invalid_json`: the body is not JSON

  Options are those of `Gobusgo.OneBusAway.Client.get/3`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client

  # https://developer.onebusaway.org/api/where/methods/agencies-with-coverage — checked 2026-10-01
  @path "/api/where/agencies-with-coverage.json"
  @success_code 200
  @agency_count_max 1_000

  @type coverage :: %{lat: number(), lon: number(), lat_span: number(), lon_span: number()}
  @type agency :: %{
          id: String.t(),
          name: String.t(),
          url: String.t(),
          timezone: String.t(),
          coverage: coverage()
        }
  @type error ::
          Client.failure()
          | {:http_status, 400..599}
          | {:unexpected_redirect, 300..399}
          | {:api_error, %{code: integer(), text: String.t()}}
          | :invalid_json

  @envelope_schema {:map,
                    %{
                      "code" => :integer,
                      "text" => :string,
                      "version" => :integer,
                      "currentTime" => :integer
                    }}

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
  def fetch(%{api_key: api_key} = settings, options) when is_list(options) do
    case Client.get(settings, @path, options) do
      {:ok, %{status: status, body: body}} -> interpret(status, body, api_key)
      {:error, failure} -> {:error, failure}
    end
  end

  defp interpret(200, body, api_key) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> interpret_envelope(decoded, api_key)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp interpret(status, _body, _api_key) when status in 300..399 do
    {:error, {:unexpected_redirect, status}}
  end

  defp interpret(status, _body, _api_key) when status in 400..599 do
    {:error, {:http_status, status}}
  end

  defp interpret(status, _body, _api_key) do
    raise Assert.AssertionError, message: "unexpected HTTP status #{status}"
  end

  defp interpret_envelope(decoded, api_key) do
    %{"code" => code, "text" => text} = Assert.schema(decoded, @envelope_schema)

    if code == @success_code do
      {:ok, decoded |> Map.fetch!("data") |> parse_data()}
    else
      {:error, {:api_error, %{code: code, text: Client.scrub(text, api_key)}}}
    end
  end

  defp parse_data(data) do
    %{"list" => entries, "references" => %{"agencies" => references}} =
      Assert.schema(data, @data_schema)

    count = length(entries)

    Assert.condition(
      count <= @agency_count_max,
      "agency count #{count} exceeds #{@agency_count_max}"
    )

    references_by_id = Map.new(references, &{&1["id"], &1})
    Enum.map(entries, &resolve(&1, references_by_id))
  end

  defp resolve(%{"agencyId" => id} = entry, references_by_id) do
    reference = Map.get(references_by_id, id)
    Assert.condition(reference != nil, "list entry #{inspect(id)} has no agency reference")

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
end
