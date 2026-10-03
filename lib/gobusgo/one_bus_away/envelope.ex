defmodule Gobusgo.OneBusAway.Envelope do
  @moduledoc """
  The response envelope every OneBusAway method wraps its `data` in. Pure.

  `interpret/2` turns an HTTP status and body into the decoded envelope of a
  successful response, or into the documented failure it reports:

    * `{:http_status, status}`: a 4xx or 5xx response
    * `{:unexpected_redirect, status}`: a 3xx response, never followed
    * `{:api_error, %{code: code, text: text}}`: HTTP 200 with a non-200 envelope code
    * `:invalid_json`: the body is not JSON

  A status the documentation does not account for, or an envelope that
  breaks its schema, raises `Gobusgo.Assert.AssertionError`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client

  # https://developer.onebusaway.org/api/where — checked 2026-10-02
  @success_code 200

  @type failure ::
          {:http_status, 400..599}
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

  @doc """
  Returns the decoded envelope of `response`, with `api_key` replaced wherever
  the server echoes it, or the failure the response reports.
  """
  @spec interpret(Client.response(), String.t()) ::
          {:ok, %{String.t() => term()}} | {:error, failure()}
  def interpret(%{status: 200, body: body}, api_key) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> interpret_decoded(decoded, api_key)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def interpret(%{status: status}, _api_key) when status in 300..399 do
    {:error, {:unexpected_redirect, status}}
  end

  def interpret(%{status: status}, _api_key) when status in 400..599 do
    {:error, {:http_status, status}}
  end

  def interpret(%{status: status}, _api_key) do
    raise Assert.AssertionError, message: "unexpected HTTP status #{status}"
  end

  defp interpret_decoded(decoded, api_key) do
    %{"code" => code, "text" => text} =
      envelope = decoded |> Assert.schema(@envelope_schema) |> Client.scrub(api_key)

    if code == @success_code do
      {:ok, envelope}
    else
      {:error, {:api_error, %{code: code, text: text}}}
    end
  end
end
