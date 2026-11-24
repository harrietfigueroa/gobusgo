defmodule Gobusgo.Test.CorePages do
  @moduledoc """
  What the core page check does with a browser: it opens a session whose
  clock is pinned, reads what a rider sees in the regions a scenario names,
  and compares what the two cores rendered.

  A region is an element of the page or of an MCP App's frame, read as its
  accessibility snapshot and its rendered text, or the data of the map's
  GeoJSON sources, or the model's context an MCP host received. A read is
  repeated until two reads in a row agree, so a region still drawing is
  never compared, and a region that never settles fails with what it held.
  No pixel is read.

  Each session records a Playwright trace, which `keep_traces/2` writes out
  when the cores differ and which is dropped otherwise.
  """

  alias PhoenixTest.Playwright
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Tracing

  @page_probe_path Path.expand("core_pages/page_probe.js", __DIR__)
  @map_sources_path Path.expand("core_pages/map_sources.js", __DIR__)
  @mcp_host_path Path.expand("core_pages/mcp_host.js", __DIR__)
  @external_resource @page_probe_path
  @external_resource @map_sources_path
  @external_resource @mcp_host_path
  @page_probe File.read!(@page_probe_path)
  @map_sources File.read!(@map_sources_path)
  @mcp_host File.read!(@mcp_host_path)

  @timeout_ms 10_000
  # A region a scenario names and a page lacks is read as missing after
  # this long, since the reads repeat until they settle.
  @read_timeout_ms 1_000
  @settle_interval_ms 300
  @settle_read_count_max 40
  @app_frame_selector "#mcp-app"

  @typedoc """
  A region a scenario compares: an element of the page or of the app's
  frame by its CSS selector, the map's GeoJSON sources, or the model's
  context an MCP host received.
  """
  @type region ::
          {:page, String.t(), String.t()}
          | {:app, String.t(), String.t()}
          | {:map_sources, String.t()}
          | {:model_context, String.t()}

  @doc """
  Opens a session of the test's browser whose clock reads `pinned_at` from
  its first script, with `favorites` stored before the page reads them,
  and starts its trace.
  """
  @spec open_session(map(), %{pinned_at: DateTime.t(), favorites: [map()]}) :: Playwright.t()
  def open_session(context, %{pinned_at: %DateTime{} = pinned_at, favorites: favorites})
      when is_list(favorites) do
    config =
      context
      |> Map.take(Playwright.Config.setup_keys())
      |> Playwright.Config.validate!()

    conn = PhoenixTest.Playwright.Case.new_session(config, context)
    probe = String.replace(@page_probe, "FAVORITES", JSON.encode!(favorites))

    {:ok, _result} =
      BrowserContext.add_init_script(conn.context_id, source: probe, timeout: @timeout_ms)

    :ok = pin_clock(conn.context_id, pinned_at)

    {:ok, _result} =
      Tracing.tracing_start(conn.tracing_id,
        screenshots: true,
        snapshots: true,
        timeout: @timeout_ms
      )

    {:ok, _result} = Tracing.tracing_start_chunk(conn.tracing_id, timeout: @timeout_ms)
    conn
  end

  # Playwright's fixed time: `Date` reads the instant at every call and the
  # timers run as they would, so the page's own intervals keep working while
  # every text it writes from the clock reads one instant. PlaywrightEx
  # 0.16.0 sends the protocol's clock install and fast forward and not this
  # one, so it is sent as they are.
  # https://playwright.dev/docs/api/class-clock#clock-set-fixed-time — checked 2026-11-14
  defp pin_clock(context_id, pinned_at) do
    response =
      PlaywrightEx.Connection.send(
        PlaywrightEx.Supervisor.Connection,
        %{
          guid: context_id,
          method: :clock_set_fixed_time,
          params: %{time_number: DateTime.to_unix(pinned_at, :millisecond)}
        },
        @timeout_ms
      )

    case response do
      %{error: error} ->
        raise ExUnit.AssertionError, message: "clock not pinned: #{inspect(error)}"

      _result ->
        :ok
    end
  end

  @doc """
  Writes a host of MCP Apps into the session's page, which must be a page
  of the test server's origin, so the app's frame fetches from that origin,
  and renders `host.resource` in it with the tool's arguments and result.
  """
  @spec render_app(Playwright.t(), %{
          resource: String.t(),
          tool_input: map(),
          tool_result: map(),
          host_capabilities: map()
        }) :: Playwright.t()
  def render_app(conn, host) do
    arg = %{
      "resource" => host.resource,
      "toolInput" => host.tool_input,
      "toolResult" => host.tool_result,
      "hostCapabilities" => host.host_capabilities
    }

    Playwright.evaluate(conn, @mcp_host, is_function: true, arg: arg)
  end

  @doc """
  Waits up to `timeout_ms` for `predicate`, a JavaScript function that may
  return a promise, to answer true in the session's page.
  """
  @spec await_page(Playwright.t(), String.t(), pos_integer()) :: Playwright.t()
  def await_page(conn, predicate, timeout_ms) when is_binary(predicate) do
    case Frame.wait_for_function(conn.frame_id,
           expression: predicate,
           is_function: true,
           polling: @settle_interval_ms,
           timeout: timeout_ms
         ) do
      {:ok, _handle} ->
        conn

      {:error, error} ->
        raise ExUnit.AssertionError,
          message: "the page never got there: #{predicate}\n#{inspect(error)}"
    end
  end

  @doc "The selector of `selector` inside the app's frame, for an action or an assertion."
  @spec in_app(String.t()) :: String.t()
  def in_app(selector),
    do: "#{@app_frame_selector} >> internal:control=enter-frame >> #{selector}"

  @doc """
  Reads `regions` until two reads in a row agree, and returns the last, by
  region name. Raises with the reads when they never settle.
  """
  @spec settled_regions(Playwright.t(), [region()]) :: %{String.t() => term()}
  def settled_regions(conn, regions) when is_list(regions) do
    first = read_regions(conn, regions)
    settle(conn, %{regions: regions, last: first, read_count: 1})
  end

  defp settle(conn, %{regions: regions, last: last, read_count: read_count}) do
    if read_count >= @settle_read_count_max do
      raise ExUnit.AssertionError,
        message:
          "the regions never settled in #{read_count} reads; the last:\n#{inspect(last, pretty: true)}"
    end

    Process.sleep(@settle_interval_ms)
    read = read_regions(conn, regions)

    if read == last do
      read
    else
      settle(conn, %{regions: regions, last: read, read_count: read_count + 1})
    end
  end

  defp read_regions(conn, regions) do
    Map.new(regions, fn region -> {region_name(region), read_region(conn, region)} end)
  end

  defp region_name({:page, name, _selector}), do: name
  defp region_name({:app, name, _selector}), do: name
  defp region_name({:map_sources, name}), do: name
  defp region_name({:model_context, name}), do: name

  defp read_region(conn, {:page, _name, selector}) do
    %{
      accessibility: accessibility(conn, selector),
      text: text(conn, "document", selector)
    }
  end

  defp read_region(conn, {:app, _name, selector}) do
    %{
      accessibility: accessibility(conn, in_app(selector)),
      text:
        text(
          conn,
          "document.querySelector(#{JSON.encode!(@app_frame_selector)}).contentDocument",
          selector
        )
    }
  end

  defp read_region(conn, {:map_sources, _name}) do
    evaluate(conn, @map_sources, nil)
  end

  defp read_region(conn, {:model_context, _name}) do
    evaluate(conn, "() => window.__corePagesHost.context", nil)
  end

  # The accessibility snapshot of the element `selector` names, or `:missing`
  # where no element matches it.
  defp accessibility(conn, selector) do
    case Frame.aria_snapshot_json(conn.frame_id, selector: selector, timeout: @read_timeout_ms) do
      {:ok, snapshot} -> snapshot
      {:error, _error} -> :missing
    end
  end

  # The text the element shows, as `innerText` renders it, or nil where no
  # element matches.
  defp text(conn, document_expression, selector) do
    expression = """
    (selector) => {
      const element = #{document_expression}.querySelector(selector)
      return element === null ? null : element.innerText
    }
    """

    evaluate(conn, expression, selector)
  end

  defp evaluate(conn, expression, arg) do
    case Frame.evaluate(conn.frame_id,
           expression: expression,
           is_function: true,
           arg: arg,
           timeout: @timeout_ms
         ) do
      {:ok, value} ->
        value

      {:error, error} ->
        raise ExUnit.AssertionError, message: "the page did not answer: #{inspect(error)}"
    end
  end

  @doc """
  The regions of `regions`, a read of `settled_regions/2`, that show
  nothing, by name, sorted: an element no selector matched or with no text,
  a map with no source, or a host that received no context.
  """
  @spec empty_regions(%{String.t() => term()}) :: [String.t()]
  def empty_regions(regions) when is_map(regions) do
    for {name, read} <- Enum.sort(regions), empty?(read), do: name
  end

  defp empty?(%{accessibility: :missing}), do: true
  defp empty?(%{text: text}), do: text in [nil, ""]
  defp empty?(read), do: read in [nil, [], %{}]

  @doc """
  The regions whose reads differ between `reference` and `other`, each by
  name, sorted.
  """
  @spec differences(%{String.t() => term()}, %{String.t() => term()}) :: [String.t()]
  def differences(reference, other) when is_map(reference) and is_map(other) do
    names = reference |> Map.keys() |> Enum.concat(Map.keys(other)) |> Enum.uniq() |> Enum.sort()
    Enum.reject(names, &(Map.get(reference, &1) == Map.get(other, &1)))
  end

  @doc """
  Stops the trace of every session in `sessions`, each `{label, conn}`,
  and writes it to `dir` under its label; returns the paths written.
  """
  @spec keep_traces([{String.t(), Playwright.t()}], String.t()) :: [String.t()]
  def keep_traces(sessions, dir) when is_list(sessions) and is_binary(dir) do
    File.mkdir_p!(dir)

    for {label, conn} <- sessions do
      {:ok, zip_file} = Tracing.tracing_stop_chunk(conn.tracing_id, timeout: @timeout_ms)
      {:ok, _result} = Tracing.tracing_stop(conn.tracing_id, timeout: @timeout_ms)
      path = Path.join(dir, String.replace(label, ~r/[^a-zA-Z0-9.-]+/, "_") <> ".zip")
      File.cp!(zip_file.absolute_path, path)
      path
    end
  end
end
