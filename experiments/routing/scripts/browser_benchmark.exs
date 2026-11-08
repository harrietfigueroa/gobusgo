# Runs the browser benchmark page in a headless Chrome on this machine and
# prints its results, the desktop browser row beside the node runner's.
# Start `node experiments/routing/bench/serve.mjs` first, then run
#
#   MIX_ENV=test mix run --no-start experiments/routing/scripts/browser_benchmark.exs <path of the Chrome executable>
#
# The page runs in real time: it waits for the results to appear, at most
# five minutes.

alias Gobusgo.Test.Chrome

[executable] = System.argv()
url = "http://127.0.0.1:8232/experiments/routing/bench/index.html"
poll_interval_ms = 1_000
poll_count_max = 300

profile_dir =
  Path.join(System.tmp_dir!(), "gobusgo-routing-#{System.unique_integer([:positive])}")

browser = Chrome.start(%{executable: executable, profile_dir: profile_dir})

call = fn browser, session_id, method, params ->
  Chrome.call(browser, %{method: method, params: params, session_id: session_id})
end

read_results = fn browser, session_id ->
  {%{"result" => %{"value" => text}}, browser} =
    call.(browser, session_id, "Runtime.evaluate", %{
      expression: "document.getElementById('results').textContent",
      returnByValue: true
    })

  {text, browser}
end

try do
  {%{"targetId" => target_id}, browser} =
    call.(browser, nil, "Target.createTarget", %{url: "about:blank"})

  {%{"sessionId" => session_id}, browser} =
    call.(browser, nil, "Target.attachToTarget", %{targetId: target_id, flatten: true})

  {_result, browser} = call.(browser, session_id, "Page.navigate", %{url: url})
  Process.sleep(2_000)

  {_result, browser} =
    call.(browser, session_id, "Runtime.evaluate", %{
      expression: "document.getElementById('run').click()"
    })

  result =
    Enum.reduce_while(1..poll_count_max, browser, fn _poll, browser ->
      Process.sleep(poll_interval_ms)
      {text, browser} = read_results.(browser, session_id)

      if String.starts_with?(text, "{") or String.starts_with?(text, "Failed") do
        {:halt, text}
      else
        {:cont, browser}
      end
    end)

  IO.puts(result)
after
  :ok = Chrome.stop(browser)
end
