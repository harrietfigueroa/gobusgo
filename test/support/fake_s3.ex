defmodule Gobusgo.Test.FakeS3 do
  @moduledoc """
  A bucket held in memory that answers the requests of
  `Gobusgo.S3.Client` as S3 documents them, for tests of the S3 backends: a
  conditional `PutObject`, `GetObject`, `HeadObject`, `DeleteObject`, and
  `ListObjectsV2` with a prefix, a start, a continuation token, and a key
  count.

  `start/0` starts a bucket under the test's supervisor and returns it, and
  `options/1` are the backend options that reach it. `answer_next/2` makes
  the bucket answer its next requests with given statuses and leave its
  objects as they are, and `requests/1` returns what it was asked, the
  oldest first.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @key_count_default 1000

  @doc "Starts an empty bucket."
  @spec start() :: pid()
  def start do
    {Agent, fn -> %{objects: %{}, statuses: [], requests: []} end}
    |> Supervisor.child_spec(id: make_ref())
    |> start_supervised!()
  end

  @doc "The options with which a backend reaches `bucket`, storing under `prefix`."
  @spec options(pid(), String.t()) :: Keyword.t()
  def options(bucket, prefix \\ "") do
    [
      prefix: prefix,
      endpoint: "https://bucket.s3.us-west-2.amazonaws.com",
      region: "us-west-2",
      credentials: fn ->
        {:ok, %{access_key_id: "ASIAEXAMPLE", secret_access_key: "secret", token: "token"}}
      end,
      plug: plug(bucket),
      retry_delay_ms_base: 1
    ]
  end

  @doc "Stores `body` under `key`, whatever the key holds."
  @spec put(pid(), String.t(), binary()) :: :ok
  def put(bucket, key, body \\ "x") do
    Agent.update(bucket, &put_in(&1.objects[key], body))
  end

  @doc "The keys the bucket holds, in order."
  @spec keys(pid()) :: [String.t()]
  def keys(bucket), do: bucket |> Agent.get(&Map.keys(&1.objects)) |> Enum.sort()

  @doc "The body the bucket holds under `key`, or `nil`."
  @spec get(pid(), String.t()) :: binary() | nil
  def get(bucket, key), do: Agent.get(bucket, & &1.objects[key])

  @doc "Makes the bucket answer one request with each of `statuses`, in order."
  @spec answer_next(pid(), [pos_integer()]) :: :ok
  def answer_next(bucket, statuses), do: Agent.update(bucket, &%{&1 | statuses: statuses})

  @doc "Every request the bucket was asked, as `{method, path, query}`, the oldest first."
  @spec requests(pid()) :: [{String.t(), String.t(), %{String.t() => String.t()}}]
  def requests(bucket), do: bucket |> Agent.get(& &1.requests) |> Enum.reverse()

  defp plug(bucket) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 32 * 1024 * 1024)
      "/" <> key = conn.request_path
      request = {conn.method, conn.request_path, conn.query_params}

      forced =
        Agent.get_and_update(bucket, fn state ->
          state = %{state | requests: [request | state.requests]}

          case state.statuses do
            [status | rest] -> {status, %{state | statuses: rest}}
            [] -> {nil, state}
          end
        end)

      case forced do
        nil -> answer(conn, bucket, %{key: key, body: body})
        status -> Plug.Conn.send_resp(conn, status, "")
      end
    end
  end

  defp answer(%{method: "GET"} = conn, bucket, %{key: ""}) do
    Plug.Conn.send_resp(conn, 200, listing(Agent.get(bucket, & &1.objects), conn.query_params))
  end

  defp answer(%{method: method} = conn, bucket, %{key: key}) when method in ["GET", "HEAD"] do
    case get(bucket, key) do
      nil -> Plug.Conn.send_resp(conn, 404, error("NoSuchKey"))
      body -> Plug.Conn.send_resp(conn, 200, body)
    end
  end

  defp answer(%{method: "PUT"} = conn, bucket, %{key: key, body: body}) do
    conditional = Plug.Conn.get_req_header(conn, "if-none-match") == ["*"]

    stored =
      Agent.get_and_update(bucket, fn state ->
        if conditional and is_map_key(state.objects, key) do
          {false, state}
        else
          {true, put_in(state.objects[key], body)}
        end
      end)

    if stored do
      Plug.Conn.send_resp(conn, 200, "")
    else
      Plug.Conn.send_resp(conn, 412, error("PreconditionFailed"))
    end
  end

  defp answer(%{method: "DELETE"} = conn, bucket, %{key: key}) do
    Agent.update(bucket, &%{&1 | objects: Map.delete(&1.objects, key)})
    Plug.Conn.send_resp(conn, 204, "")
  end

  defp error(code), do: "<Error><Code>#{code}</Code></Error>"

  defp listing(objects, params) do
    prefix = Map.get(params, "prefix", "")
    key_count = params |> Map.get("max-keys", "#{@key_count_default}") |> String.to_integer()

    after_key =
      case params do
        %{"continuation-token" => token} -> Base.decode64!(token)
        %{"start-after" => start_after} -> start_after
        _other -> ""
      end

    matching =
      objects
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 > after_key))

    {listed, rest} = Enum.split(matching, key_count)

    continuation =
      case rest do
        [] ->
          "<IsTruncated>false</IsTruncated>"

        _more ->
          token = listed |> List.last() |> Base.encode64()

          "<IsTruncated>true</IsTruncated><NextContinuationToken>#{token}</NextContinuationToken>"
      end

    contents =
      Enum.map_join(listed, fn key ->
        "<Contents><Key>#{URI.encode(key, &URI.char_unreserved?/1)}</Key></Contents>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      continuation <> contents <> "</ListBucketResult>"
  end
end
