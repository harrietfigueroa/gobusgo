defmodule Gobusgo.OneBusAway.ClientTest do
  # Verifies host/1 as a pure function of the settings, and get/3 where it
  # meets the request gate: each case starts a gate of its own, serves the
  # request from a Req.Test stub, and observes what get/3 returns and what
  # the gate grants afterwards. The outcomes of a request itself are
  # exercised through the requester tests.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RequestGate

  @moduletag capture_log: true

  @stub_name Client
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}
  @path "/api/where/example.json"

  defp start_gate(limits) do
    start_supervised!({RequestGate, Keyword.merge([name: nil, refill_interval_ms: 1], limits)})
  end

  defp get(gate, options \\ []) do
    options =
      Keyword.merge(
        [plug: {Req.Test, @stub_name}, gate: gate, max_retries: 0, retry_delay_ms_base: 1],
        options
      )

    Client.get(@settings, @path, options)
  end

  defp stub_status(status, headers \\ []) do
    Req.Test.stub(@stub_name, fn conn ->
      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  # Serves each status once, in order, and counts the attempts.
  defp stub_statuses(statuses) do
    attempts = :counters.new(1, [])

    Req.Test.stub(@stub_name, fn conn ->
      :counters.add(attempts, 1, 1)
      Plug.Conn.send_resp(conn, Enum.at(statuses, :counters.get(attempts, 1) - 1), "")
    end)

    attempts
  end

  defp elapsed_ms(function) do
    started_at_ms = System.monotonic_time(:millisecond)
    result = function.()
    {result, System.monotonic_time(:millisecond) - started_at_ms}
  end

  describe "get/3 permits" do
    test "takes a permit for every attempt, a retry included" do
      gate = start_gate(refill_interval_ms: 120)
      attempts = stub_statuses([500, 200])

      assert {{:ok, %{status: 200}}, elapsed_ms} = elapsed_ms(fn -> get(gate, max_retries: 1) end)
      assert :counters.get(attempts, 1) == 2
      assert elapsed_ms >= 100
    end

    test "returns rate_limited when no permit comes before the deadline" do
      gate = start_gate(in_flight_count_max: 1)
      {:ok, _permit} = RequestGate.acquire(gate, 1_000)
      stub_status(200)

      assert get(gate, deadline_ms: 400) == {:error, :rate_limited}
    end

    test "returns rate_limited when the gate's waiters are at their bound" do
      gate = start_gate(in_flight_count_max: 1, waiter_count_max: 1)
      {:ok, _permit} = RequestGate.acquire(gate, 1_000)
      _waiter = Task.async(fn -> RequestGate.acquire(gate, 5_000) end)
      Process.sleep(20)
      stub_status(200)

      assert {{:error, :rate_limited}, elapsed_ms} = elapsed_ms(fn -> get(gate) end)
      assert elapsed_ms < 200
    end

    for {name, arrange} <- [
          {"a response", quote(do: stub_status(200))},
          {"a transport failure",
           quote(do: Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :econnrefused)))},
          {"a request killed at its deadline",
           quote(
             do:
               Req.Test.stub(@stub_name, fn conn ->
                 Process.sleep(2_000)
                 Plug.Conn.send_resp(conn, 200, "")
               end)
           )}
        ] do
      test "frees its permit after #{name}" do
        gate = start_gate(in_flight_count_max: 1)
        unquote(arrange)

        _result = get(gate, deadline_ms: 300)

        assert {:ok, _permit} = RequestGate.acquire(gate, 200)
      end
    end
  end

  describe "get/3 with a 429 response" do
    test "returns the response without a retry" do
      gate = start_gate([])
      attempts = stub_statuses([429, 200])

      assert {:ok, %{status: 429}} = get(gate, max_retries: 2)
      assert :counters.get(attempts, 1) == 1
    end

    test "pauses the gate for the time Retry-After names" do
      gate = start_gate(pause_ms_base: 1, pause_ms_max: 1)
      stub_status(429, [{"retry-after", "2"}])
      {:ok, %{status: 429}} = get(gate)
      stub_status(200)

      assert get(gate, deadline_ms: 500) == {:error, :rate_limited}
    end

    for {name, headers} <- [
          {"no Retry-After", []},
          {"a malformed Retry-After", [{"retry-after", "soon"}]}
        ] do
      test "pauses the gate inside its own backoff window for #{name}" do
        gate = start_gate(pause_ms_base: 200, pause_ms_max: 200)
        stub_status(429, unquote(headers))
        {:ok, %{status: 429}} = get(gate)
        stub_status(200)

        assert {{:ok, %{status: 200}}, elapsed_ms} = elapsed_ms(fn -> get(gate) end)
        assert elapsed_ms >= 80
      end
    end

    test "reopens the gate with the first response that is not a 429" do
      gate = start_gate(pause_ms_base: 1, pause_ms_max: 1)
      stub_status(429)
      {:ok, %{status: 429}} = get(gate)
      stub_status(200)
      {:ok, %{status: 200}} = get(gate)

      assert {{:ok, %{status: 200}}, elapsed_ms} = elapsed_ms(fn -> get(gate) end)
      assert elapsed_ms < 200
    end
  end

  describe "host/1" do
    for {name, base_url, expected} <- [
          {"a bare origin", "https://oba.example.test", "oba.example.test"},
          {"an origin with a port and a path", "https://oba.example.test:8443/base",
           "oba.example.test"},
          {"an origin with user information", "https://user:secret@oba.example.test",
           "oba.example.test"}
        ] do
      test "returns the host name alone for #{name}" do
        settings = %{base_url: unquote(base_url), api_key: "test-key"}

        assert Client.host(settings) == unquote(expected)
      end
    end

    test "raises for a base URL without a host" do
      assert_raise AssertionError, ~r/host/, fn ->
        Client.host(%{base_url: "not a url", api_key: "test-key"})
      end
    end

    test "keeps the base URL out of the raised message" do
      exception =
        assert_raise AssertionError, fn ->
          Client.host(%{base_url: "user:secret-3f9a", api_key: "test-key"})
        end

      refute exception.message =~ "secret-3f9a"
    end
  end
end
