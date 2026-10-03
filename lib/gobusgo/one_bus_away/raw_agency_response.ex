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

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Destination
  alias Gobusgo.OneBusAway.Agencies
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @type t :: %{
          destination: String.t(),
          content: binary(),
          fetched_at: DateTime.t(),
          data_sha256: String.t()
        }

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
  @type parse_error :: :invalid_json | :schema_mismatch | :hash_mismatch | :destination_mismatch

  @destination_prefix "raw/oba/agencies-with-coverage"
  @extension_uncompressed ".json"
  @extension @extension_uncompressed <> Compression.suffix()
  @fetched_at_name_bytes byte_size("20261002T031500Z")
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

  @wrapper_schema {:map,
                   %{
                     "meta" =>
                       {:map,
                        %{
                          "fetchedAt" => :string,
                          "dataSha256" => :string,
                          "requestId" => :string
                        }},
                     "body" => @envelope_schema
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

  @doc """
  Returns the prefix shared by every destination whose fetch time falls on the
  UTC `date`.
  """
  @spec partition_prefix(Date.t()) :: String.t()
  def partition_prefix(%Date{} = date) do
    @destination_prefix <> "/dt=" <> Date.to_iso8601(date) <> "/"
  end

  @doc """
  Returns the fetch time the name of `destination` carries, or `:error` when
  the name does not start with one.
  """
  @spec fetched_at(String.t()) :: {:ok, DateTime.t()} | :error
  def fetched_at(destination) when is_binary(destination) do
    destination
    |> String.split("/")
    |> List.last()
    |> case do
      <<stamp::binary-size(@fetched_at_name_bytes), "_", _rest::binary>> ->
        case DateTime.from_iso8601(stamp, :basic) do
          {:ok, fetched_at, 0} -> {:ok, fetched_at}
          _other -> :error
        end

      _other ->
        :error
    end
  end

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
    with {:ok, %{"meta" => meta, "body" => %{"data" => data}}} <- decode(content),
         {:ok, fetched_at} <- parse_fetched_at(meta["fetchedAt"]),
         data_sha256 = data_sha256(data),
         :ok <- check(data_sha256 == meta["dataSha256"], :hash_mismatch),
         request_id = meta["requestId"],
         stem = destination_stem(fetched_at, request_id, data_sha256),
         named = [stem <> @extension, stem <> @extension_uncompressed],
         :ok <- check(destination in named, :destination_mismatch),
         :ok <- check(RequestId.valid?(request_id), :schema_mismatch),
         {:ok, agencies} <- parse_agencies(data) do
      {:ok,
       %{
         destination: destination,
         fetched_at: fetched_at,
         data_sha256: data_sha256,
         request_id: request_id,
         agencies: agencies
       }}
    end
  end

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, decoded} -> check_schema(decoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp check_schema(decoded) do
    case Schema.mismatch(decoded, @wrapper_schema) do
      nil -> {:ok, decoded}
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  # Only the exact text `build/1` writes is accepted, which rules out other
  # offsets and precisions that name the same instant.
  defp parse_fetched_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, fetched_at, 0} ->
        check(DateTime.to_iso8601(fetched_at, :extended) == text, :schema_mismatch, fetched_at)

      _other ->
        {:error, :schema_mismatch}
    end
  end

  defp parse_agencies(data) do
    case Agencies.parse(data) do
      {:ok, agencies} -> check(identifiable?(agencies), :schema_mismatch, agencies)
      {:error, _reason} -> {:error, :schema_mismatch}
    end
  end

  defp identifiable?(agencies) do
    ids = Enum.map(agencies, & &1.id)
    "" not in ids and ids == Enum.uniq(ids)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp check(true, _reason, value), do: {:ok, value}
  defp check(false, reason, _value), do: {:error, reason}

  defp destination(fetched_at, request_id, data_sha256) do
    destination = destination_stem(fetched_at, request_id, data_sha256) <> @extension

    Assert.condition(
      match?({:ok, _segments}, Destination.validate(destination)),
      "built an invalid destination"
    )

    Assert.condition(Compression.compressed?(destination), "destination must be compressed")

    destination
  end

  defp destination_stem(fetched_at, request_id, data_sha256) do
    name =
      Enum.join(
        [
          DateTime.to_iso8601(fetched_at, :basic),
          request_id,
          binary_part(data_sha256, 0, @hash_prefix_size)
        ],
        "_"
      )

    partition_prefix(DateTime.to_date(fetched_at)) <> name
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

  defp encode(value), do: CanonicalJson.encode(value)
end
