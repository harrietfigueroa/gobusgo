defmodule Gobusgo.S3.CredentialsTest do
  # Answers the credentials endpoint from a Req.Test stub and observes what
  # `fetch/1` returns as the clock moves toward the expiration: when it
  # requests again, what it returns for a refresh that fails, and that no
  # credential reaches a log line or the reported state.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.S3.Credentials

  @stub_name __MODULE__
  @start ~U[2026-10-11 12:00:00Z]

  defp body(overrides \\ %{}) do
    JSON.encode!(
      Map.merge(
        %{
          "AccessKeyId" => "ASIAEXAMPLE",
          "SecretAccessKey" => "secret-value",
          "Token" => "token-value",
          "Expiration" => "2026-10-11T13:00:00Z"
        },
        overrides
      )
    )
  end

  # Serves each {status, body} once, in order, then the last one again.
  defp stub_responses(responses) do
    attempts = :counters.new(1, [])
    recipient = self()

    Req.Test.stub(@stub_name, fn conn ->
      :counters.add(attempts, 1, 1)
      send(recipient, {:requested, Plug.Conn.get_req_header(conn, "authorization")})
      index = min(:counters.get(attempts, 1), length(responses)) - 1
      {status, body} = Enum.at(responses, index)
      Plug.Conn.send_resp(conn, status, body)
    end)

    attempts
  end

  defp start(context, overrides \\ []) do
    clock = start_supervised!({Agent, fn -> @start end}, id: :clock)
    name = Module.concat(__MODULE__, "T#{context.line}")

    options =
      Keyword.merge(
        [
          name: name,
          source: %{url: "http://169.254.170.2/v2/credentials/id", authorization: nil},
          plug: {Req.Test, @stub_name},
          clock: fn -> Agent.get(clock, & &1) end
        ],
        overrides
      )

    server = start_supervised!({Credentials, options})
    Req.Test.allow(@stub_name, self(), server)
    %{server: name, clock: clock}
  end

  defp advance(clock, seconds), do: Agent.update(clock, &DateTime.add(&1, seconds, :second))

  test "returns the credentials the endpoint answers with", context do
    stub_responses([{200, body()}])
    %{server: server} = start(context)

    assert Credentials.fetch(server) ==
             {:ok,
              %{
                access_key_id: "ASIAEXAMPLE",
                secret_access_key: "secret-value",
                token: "token-value"
              }}
  end

  test "sends the authorization header of its source", context do
    stub_responses([{200, body()}])

    %{server: server} =
      start(context, source: %{url: "http://localhost/creds", authorization: "Basic abcd"})

    Credentials.fetch(server)

    assert_received {:requested, ["Basic abcd"]}
  end

  test "requests once while the credentials are far from their expiration", context do
    attempts = stub_responses([{200, body()}])
    %{server: server, clock: clock} = start(context)

    Credentials.fetch(server)
    advance(clock, 54 * 60)
    Credentials.fetch(server)

    assert :counters.get(attempts, 1) == 1
  end

  test "requests again within five minutes of the expiration", context do
    newer = body(%{"AccessKeyId" => "ASIANEWER", "Expiration" => "2026-10-11T14:00:00Z"})
    stub_responses([{200, body()}, {200, newer}])
    %{server: server, clock: clock} = start(context)

    Credentials.fetch(server)
    advance(clock, 56 * 60)

    assert {:ok, %{access_key_id: "ASIANEWER"}} = Credentials.fetch(server)
  end

  test "returns the credentials held when a refresh fails before they expire", context do
    stub_responses([{200, body()}, {500, ""}])
    %{server: server, clock: clock} = start(context)
    Credentials.fetch(server)
    advance(clock, 56 * 60)

    log =
      capture_log(fn ->
        assert {:ok, %{access_key_id: "ASIAEXAMPLE"}} = Credentials.fetch(server)
      end)

    assert log =~ "S3 credentials refresh failed"
  end

  test "is unavailable when a refresh fails after the credentials expired", context do
    stub_responses([{200, body()}, {500, ""}])
    %{server: server, clock: clock} = start(context)
    Credentials.fetch(server)
    advance(clock, 61 * 60)

    log = capture_log(fn -> assert Credentials.fetch(server) == {:error, :unavailable} end)

    assert log =~ "S3 credentials unavailable"
  end

  for {name, response} <- [
        {"a status other than 200", {404, ""}},
        {"a body that is not JSON", {200, "not json"}},
        {"a body without a secret", {200, ~s({"AccessKeyId":"a","Token":"t","Expiration":"x"})}},
        {"an expiration that is no time",
         {200, ~s({"AccessKeyId":"a","SecretAccessKey":"s","Token":"t","Expiration":"tomorrow"})}}
      ] do
    test "is unavailable for #{name}", context do
      stub_responses([unquote(response)])
      %{server: server} = start(context)

      capture_log(fn -> assert Credentials.fetch(server) == {:error, :unavailable} end)
    end
  end

  test "is unavailable when the endpoint cannot be reached", context do
    Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :econnrefused))
    %{server: server} = start(context)

    capture_log(fn -> assert Credentials.fetch(server) == {:error, :unavailable} end)
  end

  test "reports its state without the credentials", context do
    stub_responses([{200, body()}])
    %{server: server} = start(context)
    Credentials.fetch(server)

    status = inspect(:sys.get_status(server), limit: :infinity)

    refute status =~ "secret-value"
    refute status =~ "token-value"
  end
end
