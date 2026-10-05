defmodule Gobusgo.Test.Chrome do
  @call_timeout_ms 30_000
  @exit_timeout_ms 10_000

  @moduledoc """
  A headless Chrome driven over the DevTools protocol, for measurements that
  need a real browser. Chrome is started as a port of the calling process
  and speaks the protocol over the port's pipe, so only that process can use
  the browser, and the browser stops with it.

  A browser is a value: each function that talks to Chrome returns the
  browser to use next. `call/2` waits at most #{@call_timeout_ms} ms for its
  answer and keeps the events that arrive before it, which `take_events/1`
  hands over.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Test.Chrome.Frames

  @type event :: %{String.t() => term()}

  @opaque t :: %{
            port: port(),
            profile_dir: String.t(),
            buffer: binary(),
            call_id_next: pos_integer(),
            events: [event()]
          }

  @doc """
  Starts the Chrome at `executable` with a new profile in `profile_dir`, a
  directory that does not exist yet.
  """
  @spec start(%{executable: String.t(), profile_dir: String.t()}) :: t()
  def start(%{executable: executable, profile_dir: profile_dir})
      when is_binary(executable) and is_binary(profile_dir) do
    Assert.condition(File.regular?(executable), "executable must be a file: #{executable}")
    Assert.condition(not File.exists?(profile_dir), "profile_dir must not exist: #{profile_dir}")

    # Chrome reads the protocol on file descriptor 3 and writes it on 4,
    # the two a port opened with :nouse_stdio talks over.
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :nouse_stdio,
        :exit_status,
        args: [
          "--headless=new",
          "--remote-debugging-pipe",
          "--user-data-dir=#{profile_dir}",
          "--no-first-run",
          "--no-default-browser-check",
          "about:blank"
        ]
      ])

    %{port: port, profile_dir: profile_dir, buffer: "", call_id_next: 1, events: []}
  end

  @doc """
  Calls `call.method` with `call.params` in the session `call.session_id`,
  or in the browser itself when that is `nil`, and returns the result. Raises
  when Chrome answers with an error, stops, or does not answer in time.
  """
  @spec call(t(), %{method: String.t(), params: map(), session_id: String.t() | nil}) ::
          {map(), t()}
  def call(
        %{port: port, call_id_next: call_id} = browser,
        %{method: method, params: params} = call
      )
      when is_binary(method) and is_map(params) do
    message =
      case call.session_id do
        nil -> %{id: call_id, method: method, params: params}
        session_id -> %{id: call_id, method: method, params: params, sessionId: session_id}
      end

    true = Port.command(port, Frames.frame(JSON.encode!(message)))
    deadline_ms = System.monotonic_time(:millisecond) + @call_timeout_ms
    await(%{browser | call_id_next: call_id + 1}, %{id: call_id, method: method}, deadline_ms)
  end

  @doc "Returns the events received since the last call of this function, oldest first."
  @spec take_events(t()) :: {[event()], t()}
  def take_events(%{events: events} = browser),
    do: {Enum.reverse(events), %{browser | events: []}}

  @doc "Closes the browser, waits for Chrome to exit, and removes the profile directory."
  @spec stop(t()) :: :ok
  def stop(%{port: port, profile_dir: profile_dir} = browser) do
    true =
      Port.command(
        port,
        Frames.frame(JSON.encode!(%{id: browser.call_id_next, method: "Browser.close"}))
      )

    exit_deadline_ms = System.monotonic_time(:millisecond) + @exit_timeout_ms
    :ok = await_exit(port, exit_deadline_ms)
    {:ok, _removed} = File.rm_rf(profile_dir)
    :ok
  end

  # Reads from the pipe until the answer to `pending` has arrived. Each turn
  # handles one delivery of bytes, and the deadline bounds the turns.
  defp await(%{port: port, buffer: buffer} = browser, pending, deadline_ms) do
    wait_ms = deadline_ms - System.monotonic_time(:millisecond)

    Assert.condition(
      wait_ms > 0,
      "Chrome must answer #{pending.method} in #{@call_timeout_ms} ms"
    )

    receive do
      {^port, {:data, data}} ->
        {messages, rest} = Frames.split(buffer <> data)
        decoded = Enum.map(messages, &JSON.decode!/1)
        {answers, events} = Enum.split_with(decoded, &(&1["id"] == pending.id))
        browser = %{browser | buffer: rest, events: keep_events(browser.events, events)}

        case answers do
          [] -> await(browser, pending, deadline_ms)
          [%{"result" => result}] -> {result, browser}
          [%{"error" => error}] -> raise "Chrome refused #{pending.method}: #{inspect(error)}"
        end

      {^port, {:exit_status, status}} ->
        raise "Chrome exited with status #{status} before answering #{pending.method}"
    after
      wait_ms -> raise "Chrome did not answer #{pending.method} in #{@call_timeout_ms} ms"
    end
  end

  # An event has a method and no identifier; the answer to an earlier call
  # that nobody waits for has an identifier and is dropped.
  defp keep_events(kept, messages) do
    events = Enum.filter(messages, &(is_map_key(&1, "method") and not is_map_key(&1, "id")))
    Enum.reverse(events, kept)
  end

  defp await_exit(port, deadline_ms) do
    wait_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> await_exit(port, deadline_ms)
    after
      wait_ms -> raise "Chrome did not exit in #{@exit_timeout_ms} ms"
    end
  end
end
