defmodule Gobusgo.OneBusAway.RawAgencyResponse do
  @moduledoc """
  The stored form of one successful agency discovery response: its logical
  destination and its content. Everything here is pure, so the stored form is
  a function of the response and the request identifier alone.

  ## Destination

      raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json

    * `dt` is the UTC date of the fetch time.
    * `fetchedAt` is the fetch time in UTC basic ISO 8601 at second precision,
      such as `20261002T031500Z`.
    * `requestId` is the request's UUID version 7.
    * `dataHash12` is the first 12 characters of `meta.dataSha256`.

  Names within a partition sort by fetch time, and the request identifier
  makes each name unique.

  ## Content

  One JSON object, `{"meta": ..., "body": ...}`, encoded compactly with object
  keys sorted. `body` is the response envelope as decoded, re-encoded with no
  field removed. `meta` holds:

    * `fetchedAt`: the fetch time in UTC extended ISO 8601 at second precision,
      such as `2026-10-02T03:15:00Z`. It is the same instant as the one in the
      destination, and the value a half-open `[start, end)` selection compares.
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

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.RequestId

  @type t :: %{
          destination: String.t(),
          content: binary(),
          fetched_at: DateTime.t(),
          data_sha256: String.t()
        }

  @destination_prefix "raw/oba/agencies-with-coverage"
  @hash_prefix_size 12
  @http_status_stored 200
  @credential_parameter "key="
  @utc_time_zone "Etc/UTC"

  @envelope_schema {:map,
                    %{
                      "code" => {:literal, 200},
                      "version" => :integer,
                      "currentTime" => :integer,
                      "data" => {:map, %{}}
                    }}

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
    %{envelope: envelope, fetched_at: fetched_at, host: host, http_status: http_status} = response
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")

    Assert.condition(
      http_status == @http_status_stored,
      "HTTP status must be 200: #{http_status}"
    )

    Assert.condition(is_binary(host), "host must be a string")
    Assert.condition(host != "", "host must be non-empty")
    Assert.condition(fetched_at.time_zone == @utc_time_zone, "fetch time must be in UTC")

    %{"data" => data} = Assert.schema(envelope, @envelope_schema)
    fetched_at = DateTime.truncate(fetched_at, :second)
    data_sha256 = data_sha256(data)

    meta = %{
      "dataSha256" => data_sha256,
      "envelopeCurrentTime" => envelope["currentTime"],
      "envelopeVersion" => envelope["version"],
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "host" => host,
      "httpStatus" => http_status,
      "method" => response.method,
      "requestId" => request_id
    }

    destination = destination(fetched_at, request_id, data_sha256)
    assert_credential_free(%{destination: destination, meta: encode(meta)})

    %{
      destination: destination,
      content: encode(%{"meta" => meta, "body" => envelope}),
      fetched_at: fetched_at,
      data_sha256: data_sha256
    }
  end

  @doc """
  Returns the lowercase hexadecimal SHA-256 of `data` encoded as compact JSON
  with object keys sorted, so the hash is independent of key order.
  """
  @spec data_sha256(%{String.t() => term()}) :: String.t()
  def data_sha256(data) when is_map(data) do
    :sha256 |> :crypto.hash(encode(data)) |> Base.encode16(case: :lower)
  end

  defp destination(fetched_at, request_id, data_sha256) do
    name =
      Enum.join(
        [
          DateTime.to_iso8601(fetched_at, :basic),
          request_id,
          binary_part(data_sha256, 0, @hash_prefix_size)
        ],
        "_"
      )

    destination =
      Enum.join(
        [@destination_prefix, "dt=" <> Date.to_iso8601(DateTime.to_date(fetched_at)), name],
        "/"
      ) <> ".json"

    Assert.condition(
      match?({:ok, _segments}, Destination.validate(destination)),
      "built an invalid destination"
    )

    destination
  end

  # The body is exempt: it holds text the agencies supply, where `key=` is a
  # legitimate part of a link. The messages name the field and never its
  # value: the value is the leak.
  defp assert_credential_free(%{destination: destination, meta: meta}) do
    Assert.condition(
      :binary.match(destination, @credential_parameter) == :nomatch,
      "destination carries a key= parameter"
    )

    Assert.condition(
      :binary.match(meta, @credential_parameter) == :nomatch,
      "meta carries a key= parameter"
    )
  end

  defp encode(value),
    do: value |> JSON.encode_to_iodata!(&encode_sorted/2) |> IO.iodata_to_binary()

  # A map's iteration order depends on its size, so the keys are sorted to
  # make the bytes, and the hash over them, a function of the value alone.
  defp encode_sorted(value, encoder) when is_map(value) and not is_struct(value) do
    value |> Enum.sort_by(fn {key, _value} -> key end) |> :json.encode_key_value_list(encoder)
  end

  defp encode_sorted(value, encoder), do: JSON.protocol_encode(value, encoder)
end
