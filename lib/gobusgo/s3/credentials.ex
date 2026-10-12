defmodule Gobusgo.S3.Credentials do
  @refresh_margin_ms 300_000
  @attempt_count_max 2
  @connect_timeout_ms 1_000
  @receive_timeout_ms 2_000
  @retry_delay_ms_max 200
  @call_timeout_ms 10_000
  @body_bytes_max 16_384

  @moduledoc """
  The temporary credentials of the role the container runs under, fetched
  from the container credentials endpoint and held until they near their
  expiration.

  A process started with a source, the endpoint's address and the
  authorization header it asks for, holds the latest credentials. `fetch/1`
  returns them, and first requests new ones when it holds none or when the
  ones it holds expire within #{@refresh_margin_ms} ms. A request makes at
  most #{@attempt_count_max} attempts, each with #{@connect_timeout_ms} ms to
  connect and #{@receive_timeout_ms} ms to answer.

  A refresh that fails while the credentials held have not expired returns
  those, logged once at `warning` as `S3 credentials refresh failed`. A
  refresh that fails with none to return is `{:error, :unavailable}`, logged
  once at `error` as `S3 credentials unavailable`. Both lines carry the
  `reason` and no part of a credential.

  The credentials appear in no log line, and the process reports its state
  without them.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Schema

  @type t :: %{access_key_id: String.t(), secret_access_key: String.t(), token: String.t()}

  @typedoc "Where the credentials come from: the endpoint and its `authorization` header, if any."
  @type source :: %{url: String.t(), authorization: String.t() | nil}

  # https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html — checked 2026-10-11
  @response_schema {:map,
                    %{
                      "AccessKeyId" => :string,
                      "SecretAccessKey" => :string,
                      "Token" => :string,
                      "Expiration" => :string
                    }}

  @doc """
  Starts a process registered under `options[:name]` that fetches from
  `options[:source]`. `options[:plug]` answers the requests in place of the
  network, and `options[:clock]`, a zero-arity function, gives the time;
  it defaults to `DateTime.utc_now/0`.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :source, plug: nil, clock: &DateTime.utc_now/0])
    name = Keyword.fetch!(options, :name)
    %{url: url, authorization: authorization} = Keyword.fetch!(options, :source)
    clock = Keyword.fetch!(options, :clock)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_binary(url), "the source's url must be a string")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")

    server = %{
      url: url,
      authorization: authorization,
      plug: Keyword.fetch!(options, :plug),
      clock: clock,
      held: nil
    }

    GenServer.start_link(__MODULE__, server, name: name)
  end

  @doc """
  Returns the credentials `server` holds, refreshed when they near their
  expiration. Exits when the process does not answer within
  #{@call_timeout_ms} ms.
  """
  @spec fetch(GenServer.server()) :: {:ok, t()} | {:error, :unavailable}
  def fetch(server), do: GenServer.call(server, :fetch, @call_timeout_ms)

  @impl GenServer
  def init(server), do: {:ok, server}

  @impl GenServer
  def handle_call(:fetch, _from, server) do
    now = server.clock.()

    if fresh?(server.held, now) do
      {:reply, {:ok, server.held.credentials}, server}
    else
      refresh(server, now)
    end
  end

  # A crash report prints the state, which holds a secret.
  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn server ->
      %{server | held: redact(server.held), authorization: redact(server.authorization)}
    end)
  end

  defp redact(nil), do: nil
  defp redact(_secret), do: :redacted

  defp fresh?(nil, _now), do: false

  defp fresh?(%{expires_at: expires_at}, now) do
    DateTime.diff(expires_at, now, :millisecond) > @refresh_margin_ms
  end

  defp refresh(server, now) do
    case request(server) do
      {:ok, held} ->
        {:reply, {:ok, held.credentials}, %{server | held: held}}

      {:error, reason} ->
        if usable?(server.held, now) do
          Logger.warning("S3 credentials refresh failed", reason: inspect(reason))
          {:reply, {:ok, server.held.credentials}, server}
        else
          Logger.error("S3 credentials unavailable", reason: inspect(reason))
          {:reply, {:error, :unavailable}, %{server | held: nil}}
        end
    end
  end

  defp usable?(nil, _now), do: false
  defp usable?(%{expires_at: expires_at}, now), do: DateTime.after?(expires_at, now)

  defp request(%{url: url, authorization: authorization, plug: plug}) do
    request_options =
      [
        url: url,
        headers: authorization_headers(authorization),
        decode_body: false,
        compressed: false,
        redirect: false,
        retry: :transient,
        max_retries: @attempt_count_max - 1,
        retry_delay: fn _retry_count -> :rand.uniform(@retry_delay_ms_max) end,
        retry_log_level: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms]
      ] ++ plug_option(plug)

    case Req.get(request_options) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
      {:error, exception} -> {:error, {:request, exception.__struct__}}
    end
  end

  defp authorization_headers(nil), do: []
  defp authorization_headers(authorization), do: [{"authorization", authorization}]

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]

  defp parse(body) when byte_size(body) <= @body_bytes_max do
    with {:ok, decoded} <- JSON.decode(body),
         nil <- Schema.mismatch(decoded, @response_schema),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(decoded["Expiration"]) do
      {:ok,
       %{
         expires_at: expires_at,
         credentials: %{
           access_key_id: decoded["AccessKeyId"],
           secret_access_key: decoded["SecretAccessKey"],
           token: decoded["Token"]
         }
       }}
    else
      _mismatch -> {:error, :malformed}
    end
  end

  defp parse(_body), do: {:error, :malformed}
end
