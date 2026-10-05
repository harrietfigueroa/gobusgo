# Measures the memory the vehicle page holds in the browser and prints it.
#
#     MIX_ENV=test GOBUSGO_DATA_DIR=<base directory with a basemap> \
#       mix run --no-start test/scripts/vehicle_page_browser_memory.exs <path of the Chrome executable>
#
# The script serves the application in the test environment, fills the
# vehicle view with one fetch cycle of synthetic vehicles in the counts a
# real cycle had, opens the page in a headless Chrome, and applies further
# cycles at the source's pace while the page is open. It reads the page's
# JavaScript heap, the heaps of the page's workers, and the count of DOM
# nodes after the first draw and after the last cycle, each as found and
# again after a forced collection. Memory outside those heaps, such as the
# map's tiles on the graphics side, is not read.
defmodule Gobusgo.Test.VehiclePageBrowserMemory do
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Test.Chrome
  alias Gobusgo.Test.VehiclePageMemory

  # One minute of the vehicle source's five-second cycles.
  @cycle_count 12
  @cycle_interval_ms 5_000
  # The time the page gets to load the map library, draw the tiles of the
  # first view, and draw the markers.
  @draw_wait_ms 20_000
  @bytes_per_kibibyte 1024
  @page_path "/vehicles"

  @map_canvas_count """
  document.querySelectorAll(".maplibregl-canvas").length
  """

  def run([executable]) do
    Application.put_env(:phoenix, :serve_endpoints, true)
    {:ok, _started} = Application.ensure_all_started(:gobusgo)
    {:ok, %{ip: ip, port: port}} = Gobusgo.Config.http()
    url = "http://#{:inet.ntoa(ip)}:#{port}#{@page_path}"
    profile = VehiclePageMemory.fetch_profile()
    vehicle_count = Enum.sum_by(profile, & &1.vehicle_count)
    apply_cycle(profile, 0)

    profile_dir =
      Path.join(System.tmp_dir!(), "gobusgo-chrome-#{System.unique_integer([:positive])}")

    browser = Chrome.start(%{executable: executable, profile_dir: profile_dir})

    try do
      {session_id, browser} = open_page(browser, url)
      Process.sleep(@draw_wait_ms)
      {map_canvas_count, browser} = map_canvas_count(browser, session_id)

      if map_canvas_count != 1 do
        raise "the page must show one map, got: #{map_canvas_count}"
      end

      {first_draw, worker_session_ids, browser} = measure(browser, session_id, [])

      for sequence <- 1..@cycle_count do
        apply_cycle(profile, sequence)
        Process.sleep(@cycle_interval_ms)
      end

      {last_cycle, _worker_session_ids, _browser} =
        measure(browser, session_id, worker_session_ids)

      IO.puts(
        "\nVehicle page browser memory: #{vehicle_count} vehicles, #{length(profile)} agencies"
      )

      print("After the first draw", first_draw)
      print("After #{@cycle_count} more fetch cycles", last_cycle)
    after
      :ok = Chrome.stop(browser)
    end
  end

  def run(_arguments) do
    raise "usage: mix run --no-start #{__ENV__.file} <path of the Chrome executable>"
  end

  defp apply_cycle(profile, sequence) do
    for %{agency_id: agency_id, vehicle_count: vehicle_count} <- profile do
      :ok =
        VehiclePageMemory.apply_fetch(VehicleView, %{
          agency_id: agency_id,
          vehicle_count: vehicle_count,
          sequence: sequence
        })
    end
  end

  # Opens `url` in a new tab and returns the tab's session. The session
  # attaches to the workers the page starts, so their heaps can be read.
  defp open_page(browser, url) do
    {%{"targetId" => target_id}, browser} =
      call(browser, nil, "Target.createTarget", %{url: "about:blank"})

    {%{"sessionId" => session_id}, browser} =
      call(browser, nil, "Target.attachToTarget", %{targetId: target_id, flatten: true})

    {_result, browser} = call(browser, session_id, "Performance.enable", %{})

    {_result, browser} =
      call(browser, session_id, "Target.setAutoAttach", %{
        autoAttach: true,
        waitForDebuggerOnStart: false,
        flatten: true
      })

    {_result, browser} = call(browser, session_id, "Page.navigate", %{url: url})
    {session_id, browser}
  end

  defp map_canvas_count(browser, session_id) do
    {%{"result" => %{"value" => count}}, browser} =
      call(browser, session_id, "Runtime.evaluate", %{
        expression: @map_canvas_count,
        returnByValue: true
      })

    {count, browser}
  end

  # The page's reading as found, then after a collection in the page and in
  # each of its workers.
  defp measure(browser, session_id, known_worker_session_ids) do
    {events, browser} = Chrome.take_events(browser)
    worker_session_ids = worker_session_ids(known_worker_session_ids, events)
    {found, browser} = reading(browser, session_id, worker_session_ids)

    browser =
      Enum.reduce([session_id | worker_session_ids], browser, fn collected_session_id, browser ->
        {_result, browser} =
          call(browser, collected_session_id, "HeapProfiler.collectGarbage", %{})

        browser
      end)

    {collected, browser} = reading(browser, session_id, worker_session_ids)
    {[{"as found", found}, {"collected", collected}], worker_session_ids, browser}
  end

  # The sessions of the workers that are still running: the known ones and
  # the ones `events` attached, less the ones `events` detached.
  defp worker_session_ids(known, events) do
    attached =
      for %{"method" => "Target.attachedToTarget", "params" => params} <- events,
          params["targetInfo"]["type"] == "worker" do
        params["sessionId"]
      end

    detached =
      for %{"method" => "Target.detachedFromTarget", "params" => params} <- events do
        params["sessionId"]
      end

    (known ++ attached) -- detached
  end

  defp reading(browser, session_id, worker_session_ids) do
    {page_heap_bytes, browser} = heap_bytes(browser, session_id)

    {worker_heap_bytes, browser} =
      Enum.reduce(worker_session_ids, {0, browser}, fn worker_session_id, {bytes, browser} ->
        {worker_bytes, browser} = heap_bytes(browser, worker_session_id)
        {bytes + worker_bytes, browser}
      end)

    {%{"metrics" => metrics}, browser} = call(browser, session_id, "Performance.getMetrics", %{})
    [node_count] = for %{"name" => "Nodes", "value" => value} <- metrics, do: value

    reading = %{
      page_heap_bytes: page_heap_bytes,
      worker_heap_bytes: worker_heap_bytes,
      worker_count: length(worker_session_ids),
      node_count: node_count
    }

    {reading, browser}
  end

  defp heap_bytes(browser, session_id) do
    {%{"usedSize" => used_bytes}, browser} =
      call(browser, session_id, "Runtime.getHeapUsage", %{})

    {used_bytes, browser}
  end

  defp call(browser, session_id, method, params) do
    Chrome.call(browser, %{method: method, params: params, session_id: session_id})
  end

  defp print(title, readings) do
    rows =
      for {label, reading} <- readings do
        "  #{String.pad_trailing(label, 10)}" <>
          " page heap #{kibibytes(reading.page_heap_bytes)}" <>
          " worker heaps #{kibibytes(reading.worker_heap_bytes)}" <>
          " (#{reading.worker_count} workers)" <>
          " DOM nodes #{reading.node_count}"
      end

    IO.puts(Enum.join([title | rows], "\n"))
  end

  defp kibibytes(bytes) do
    kibibyte_count = div(round(bytes), @bytes_per_kibibyte)
    String.pad_leading("#{kibibyte_count} KiB", 11)
  end
end

Gobusgo.Test.VehiclePageBrowserMemory.run(System.argv())
