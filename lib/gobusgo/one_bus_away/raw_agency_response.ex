defmodule Gobusgo.OneBusAway.RawAgencyResponse do
  @moduledoc """
  The stored form of one successful agency discovery response: its logical
  destination and its content. Everything here is pure, so the stored form is
  a function of the response and the request identifier alone.

  ## Destination

      raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json.gz

    * `dt` is the UTC date of the fetch time.
    * `fetchedAt` is the fetch time in UTC basic ISO 8601 at second precision,
      such as `20261002T031500Z`.
    * `requestId` is the request's UUID version 7.
    * `dataHash12` is the first 12 characters of `meta.dataSha256`.

  Names within a partition sort by fetch time, and the request identifier
  makes each name unique. The `.gz` ending makes the writer store the content
  compressed. `parse/1` also accepts the same name ending in `.json`, the
  name of a response stored uncompressed.

  ## Content

  One JSON object, `{"meta": ..., "body": ...}`, encoded compactly with object
  keys sorted. `body` is the response envelope as decoded, re-encoded with no
  field removed. `meta` holds:

    * `fetchedAt`: the fetch time in UTC extended ISO 8601 at second precision,
      such as `2026-10-02T03:15:00Z`. It is the same instant as the one in the
      destination.
    * `host`: the server's host name, without credentials.
    * `method`: the HTTP method of the request.
    * `httpStatus`: the HTTP status of the response, always 200.
    * `envelopeVersion`: the envelope's `version`.
    * `envelopeCurrentTime`: the envelope's `currentTime`, in milliseconds
      since the Unix epoch.
    * `dataSha256`: `data_sha256/1` of the envelope's `data`.
    * `requestId`: the request identifier.

  The hash covers `data` alone, so two responses carrying the same agencies
  share a hash although their envelope `currentTime` differs.
  """

  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.RequestId

  @type t :: RawResponse.t()

  @type parsed :: %{
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          agencies: [Agencies.agency()]
        }

  @typedoc """
    * `:invalid_json` — the content is not JSON.
    * `:schema_mismatch` — the content is not the wrapper `build/1` produces,
      its data is not agency discovery data, or its data names an agency with
      an empty identifier or names one agency twice.
    * `:hash_mismatch` — the data does not hash to `meta.dataSha256`.
    * `:destination_mismatch` — `meta` names a destination other than the one
      the content was read from, under either ending.
  """
  @type parse_error :: RawResponse.parse_error()

  @destination_prefix "raw/oba/agencies-with-coverage"

  @doc "The prefix every destination of this dataset starts with."
  @spec destination_prefix() :: String.t()
  def destination_prefix, do: @destination_prefix

  @doc """
  Returns the destination and content that store `response` under
  `request_id`, with the fetch time and data hash they carry. `response` is a
  successful `t:Gobusgo.OneBusAway.Agencies.response/0` whose fetch time is in
  UTC; `request_id` is a UUID version 7. Raises
  `Gobusgo.Assert.AssertionError` when either breaks that contract, or when
  the destination or `meta` would carry a `key=` query parameter. `body` is
  stored as received, whatever text it holds.
  """
  @spec build(%{response: Agencies.response(), request_id: RequestId.t()}) :: t()
  def build(%{response: response, request_id: request_id}) do
    RawResponse.build(%{
      response: response,
      request_id: request_id,
      prefix: @destination_prefix,
      segments: [],
      meta: %{}
    })
  end

  @doc """
  Returns the lowercase hexadecimal SHA-256 of `data` encoded as compact JSON
  with object keys sorted, so the hash is independent of key order.
  """
  @spec data_sha256(%{String.t() => term()}) :: String.t()
  defdelegate data_sha256(data), to: RawResponse

  @doc """
  Returns the prefix shared by every destination whose fetch time falls on the
  UTC `date`.
  """
  @spec partition_prefix(Date.t()) :: String.t()
  def partition_prefix(%Date{} = date) do
    RawResponse.partition_prefix(@destination_prefix, date)
  end

  @doc """
  Returns the fetch time the name of `destination` carries, or `:error` when
  the name does not start with one.
  """
  @spec fetched_at(String.t()) :: {:ok, DateTime.t()} | :error
  defdelegate fetched_at(destination), to: RawResponse

  @doc """
  Returns what `content`, read back from `destination`, stored: the fetch
  time, the data hash, the request identifier, and the agencies. The content
  must be the wrapper `build/1` produces, its data must hash to the recorded
  hash, its `meta` must name `destination`, and its agencies must carry
  distinct, non-empty identifiers. The first rule it breaks returns as a
  value.
  """
  @spec parse(%{destination: String.t(), content: binary()}) ::
          {:ok, parsed()} | {:error, parse_error()}
  def parse(%{destination: destination, content: content})
      when is_binary(destination) and is_binary(content) do
    raw =
      RawResponse.parse(%{
        destination: destination,
        content: content,
        prefix: @destination_prefix,
        segments: fn _meta -> {:ok, []} end
      })

    with {:ok, %{data: data} = stored} <- raw,
         {:ok, agencies} <- parse_agencies(data) do
      {:ok,
       %{
         destination: destination,
         fetched_at: stored.fetched_at,
         data_sha256: stored.data_sha256,
         request_id: stored.request_id,
         agencies: agencies
       }}
    end
  end

  defp parse_agencies(data) do
    case Agencies.parse(data) do
      {:ok, agencies} ->
        if identifiable?(agencies) do
          {:ok, agencies}
        else
          {:error, :schema_mismatch}
        end

      {:error, _reason} ->
        {:error, :schema_mismatch}
    end
  end

  defp identifiable?(agencies) do
    ids = Enum.map(agencies, & &1.id)
    "" not in ids and ids == Enum.uniq(ids)
  end
end
