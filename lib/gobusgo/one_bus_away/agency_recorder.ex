defmodule Gobusgo.OneBusAway.AgencyRecorder do
  @moduledoc """
  Fetches agency discovery and records the successful response through
  `Gobusgo.Writer`. This module orchestrates and logs; the request lives in
  `Gobusgo.OneBusAway.Agencies`, the stored form in
  `Gobusgo.OneBusAway.RawAgencyResponse`, and the storage behind the writer.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.AgencyRecorder.record(settings, []) do
        {:ok, recorded} -> recorded.destination
        {:error, {:fetch, reason}} -> reason
        {:error, {:write, reason}} -> reason
      end

  ## Results

    * `{:ok, recorded}`: the response is stored. `recorded` holds the
      `:destination`, the `:request_id`, the `:fetched_at` time at the
      precision stored, and the `:data_sha256` of the envelope data.
    * `{:error, {:fetch, reason}}`: the request did not yield a successful
      response, and nothing is stored. `reason` is a
      `t:Gobusgo.OneBusAway.Agencies.error/0`.
    * `{:error, {:write, reason}}`: the response was fetched and the writer
      did not store it. `reason` is a `t:Gobusgo.Writer.error_reason/0`.

  Only an HTTP 200 response whose envelope code is 200 and whose payload
  matches the documented schema is stored; a payload that breaks the schema
  raises `Gobusgo.Assert.AssertionError` and nothing is stored. A write is
  create-only, so an earlier record is never replaced.

  Each call logs its outcome once: `info` when the response is recorded,
  `error` with the failed `stage` when it is not.

  ## Options

    * `:fetch_options`: options for `Gobusgo.OneBusAway.Agencies.fetch_response/2`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:request_id`: the UUID version 7 naming this request. Defaults to a new
      `Gobusgo.RequestId`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type recorded :: %{
          destination: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t()
        }
  @type error :: {:fetch, Agencies.error()} | {:write, Writer.error_reason()}

  @doc "Fetches every agency with coverage and stores the response once."
  @spec record(Client.settings(), Keyword.t()) :: {:ok, recorded()} | {:error, error()}
  def record(%{api_key: api_key} = settings, options) when is_list(options) do
    options = Keyword.validate!(options, [:request_id, fetch_options: [], write_options: []])
    request_id = Keyword.get_lazy(options, :request_id, &RequestId.generate/0)
    Assert.condition(RequestId.valid?(request_id), "request_id must be a UUID version 7")

    case Agencies.fetch_response(settings, Keyword.fetch!(options, :fetch_options)) do
      {:ok, response} ->
        stored = RawAgencyResponse.build(%{response: response, request_id: request_id})
        assert_secret_free(stored, api_key)
        write(stored, request_id, Keyword.fetch!(options, :write_options))

      {:error, reason} ->
        fail(%{stage: :fetch, reason: reason, request_id: request_id})
    end
  end

  defp write(%{destination: destination, content: content} = stored, request_id, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok ->
        recorded = %{
          destination: destination,
          request_id: request_id,
          fetched_at: stored.fetched_at,
          data_sha256: stored.data_sha256
        }

        Logger.info("OneBusAway agency response recorded",
          destination: destination,
          request_id: request_id,
          data_sha256: stored.data_sha256,
          content_bytes: byte_size(content)
        )

        {:ok, recorded}

      {:error, reason} ->
        fail(%{stage: :write, reason: reason, request_id: request_id})
    end
  end

  defp fail(%{stage: stage, reason: reason, request_id: request_id}) do
    Logger.error("OneBusAway agency response not recorded",
      stage: stage,
      reason: inspect(reason),
      request_id: request_id
    )

    {:error, {stage, reason}}
  end

  defp assert_secret_free(%{destination: destination, content: content}, api_key) do
    Assert.condition(
      :binary.match(destination, api_key) == :nomatch,
      "destination carries the key"
    )

    Assert.condition(:binary.match(content, api_key) == :nomatch, "content carries the key")
  end
end
