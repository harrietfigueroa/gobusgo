defmodule Gobusgo.S3.ClientTest do
  # Answers each request from a Req.Test stub and observes what the client
  # sends, what it returns for each status and fault, and how many attempts
  # each takes.
  use ExUnit.Case, async: true

  alias Gobusgo.S3.Client

  @stub_name __MODULE__
  @credentials %{access_key_id: "ASIAEXAMPLE", secret_access_key: "secret", token: "token-value"}
  @options [
    endpoint: "https://bucket.s3.us-west-2.amazonaws.com",
    region: "us-west-2",
    plug: {Req.Test, @stub_name},
    retry_delay_ms_base: 1
  ]

  def credentials, do: {:ok, @credentials}

  defp options(overrides \\ []) do
    @options
    |> Keyword.put(:credentials, &__MODULE__.credentials/0)
    |> Keyword.merge(overrides)
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        method: :get,
        key: "data/raw/dt=2026-10-02/a.json.gz",
        query: [],
        headers: [],
        body: nil,
        bytes_max: 1_024,
        repeatable: true
      },
      overrides
    )
  end

  # Serves each {status, body} once, in order, and counts the attempts.
  defp stub_responses(responses) do
    attempts = :counters.new(1, [])
    recipient = self()

    Req.Test.stub(@stub_name, fn conn ->
      :counters.add(attempts, 1, 1)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(recipient, {:requested, conn, body})
      {status, response_body} = Enum.at(responses, :counters.get(attempts, 1) - 1)
      Plug.Conn.send_resp(conn, status, response_body)
    end)

    attempts
  end

  describe "what a request sends" do
    test "asks the endpoint for the key with the method and the query" do
      stub_responses([{200, ""}])

      Client.request(request(%{query: [{"list-type", "2"}]}), options())

      assert_received {:requested, conn, _body}
      assert conn.method == "GET"
      assert conn.host == "bucket.s3.us-west-2.amazonaws.com"
      assert conn.request_path == "/data/raw/dt=2026-10-02/a.json.gz"
      assert conn.query_string == "list-type=2"
    end

    test "sends the body and the headers of the request" do
      stub_responses([{200, ""}])

      Client.request(
        request(%{method: :put, body: "content", headers: [{"if-none-match", "*"}]}),
        options()
      )

      assert_received {:requested, conn, "content"}
      assert Plug.Conn.get_req_header(conn, "if-none-match") == ["*"]
    end

    test "signs the request for S3 in the region with the session token" do
      stub_responses([{200, ""}])

      Client.request(request(), options())

      assert_received {:requested, conn, _body}
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert authorization =~ "AWS4-HMAC-SHA256 Credential=ASIAEXAMPLE/"
      assert authorization =~ "/us-west-2/s3/aws4_request"
      assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["token-value"]
    end
  end

  describe "what a request returns" do
    for status <- [200, 204, 403, 404, 412] do
      test "returns status #{status} with its body after one attempt" do
        attempts = stub_responses([{unquote(status), "body"}])

        assert Client.request(request(), options()) ==
                 {:ok, %{status: unquote(status), body: "body"}}

        assert :counters.get(attempts, 1) == 1
      end
    end

    test "is :body_too_large for a body past the request's bound" do
      stub_responses([{200, String.duplicate("a", 11)}])

      assert Client.request(request(%{bytes_max: 10}), options()) == {:error, :body_too_large}
    end

    test "is :credentials_unavailable when the credentials function returns an error" do
      attempts = stub_responses([{200, ""}])

      assert Client.request(request(), options(credentials: fn -> {:error, :unavailable} end)) ==
               {:error, :credentials_unavailable}

      assert :counters.get(attempts, 1) == 0
    end
  end

  describe "retries" do
    for status <- [409, 500, 502, 503, 504] do
      test "retries status #{status} and returns the answer that follows" do
        attempts = stub_responses([{unquote(status), ""}, {200, "second"}])

        assert Client.request(request(), options()) == {:ok, %{status: 200, body: "second"}}
        assert :counters.get(attempts, 1) == 2
      end
    end

    test "returns the last answer after three attempts" do
      attempts = stub_responses([{503, ""}, {503, ""}, {503, "third"}])

      assert Client.request(request(), options()) == {:ok, %{status: 503, body: "third"}}
      assert :counters.get(attempts, 1) == 3
    end

    test "retries a network fault of a repeatable request" do
      attempts = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(attempts, 1, 1)
        Req.Test.transport_error(conn, :timeout)
      end)

      assert Client.request(request(), options()) == {:error, {:transport, :timeout}}
      assert :counters.get(attempts, 1) == 3
    end

    test "returns a network fault of a request that is not repeatable after one attempt" do
      attempts = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(attempts, 1, 1)
        Req.Test.transport_error(conn, :closed)
      end)

      assert Client.request(request(%{repeatable: false}), options()) ==
               {:error, {:transport, :closed}}

      assert :counters.get(attempts, 1) == 1
    end
  end
end
