defmodule Gobusgo.Test.CorePages.Server do
  @moduledoc """
  Serves the application's endpoint over HTTP for the core page check, on a
  port of the loopback address no other listener holds, and stops and
  starts it again for the offline scenarios. The endpoint replaces the
  application's own child under `Gobusgo.Supervisor`, which a test run
  starts without a listener.
  """

  alias Gobusgo.Assert

  @endpoint GobusgoWeb.Endpoint
  @supervisor Gobusgo.Supervisor
  @loopback {127, 0, 0, 1}
  @secret_byte_count 48

  @doc "Starts serving, and returns the origin pages are loaded from."
  @spec serve() :: String.t()
  def serve do
    port = free_port()
    :ok = Supervisor.terminate_child(@supervisor, @endpoint)
    :ok = Supervisor.delete_child(@supervisor, @endpoint)

    secret = @secret_byte_count |> :crypto.strong_rand_bytes() |> Base.encode64()

    {:ok, _pid} =
      Supervisor.start_child(
        @supervisor,
        {@endpoint, http: [ip: @loopback, port: port], server: true, secret_key_base: secret}
      )

    "http://127.0.0.1:#{port}"
  end

  @doc "Stops the endpoint: its listener closes and every socket it holds drops."
  @spec stop() :: :ok
  def stop do
    Supervisor.terminate_child(@supervisor, @endpoint)
  end

  @doc "Starts the endpoint again on the port `serve/0` chose."
  @spec start() :: :ok
  def start do
    case Supervisor.restart_child(@supervisor, @endpoint) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  # A port the system hands out for a listener and takes back, so the
  # endpoint gets one no other process holds when the check starts.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: @loopback)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    Assert.condition(port > 0, "the system must hand out a port, got: #{port}")
    port
  end
end
