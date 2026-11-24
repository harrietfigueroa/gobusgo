defmodule GobusgoWeb.LayoutsTest do
  # Requests a page through the endpoint with Phoenix.ConnTest and reads the
  # document's head, which the root layout renders around every page. The
  # commit and the service worker's release file are application
  # configuration, global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint GobusgoWeb.Endpoint
  @revision "43402796c905c22db533043dee878950c74d5791"

  setup do
    configured = Application.get_env(:gobusgo, :revision)
    release_file = Application.get_env(:gobusgo, :service_worker_release_file)
    on_exit(fn -> Application.put_env(:gobusgo, :revision, configured) end)
    on_exit(fn -> restore_env(:service_worker_release_file, release_file) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gobusgo, key)
  defp restore_env(key, value), do: Application.put_env(:gobusgo, key, value)

  defp head(selector) do
    build_conn()
    |> get("/")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("head " <> selector)
  end

  defp revision_meta, do: head(~s(meta[name="revision"]))

  test "names the commit the application was built from in a revision meta element" do
    Application.put_env(:gobusgo, :revision, revision: @revision)

    assert revision_meta() |> LazyHTML.attribute("content") == [@revision]
  end

  test "has no revision meta element for an application built without a commit" do
    Application.put_env(:gobusgo, :revision, revision: nil)

    assert Enum.empty?(revision_meta())
  end

  defp release_meta, do: head(~s(meta[name="gobusgo:release"]))

  @tag :tmp_dir
  test "names the release the service worker was built for in a release meta element", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "sw_release.json")
    File.write!(path, GobusgoWeb.ServiceWorker.release_file("0123456789abcdef"))
    Application.put_env(:gobusgo, :service_worker_release_file, path)

    assert release_meta() |> LazyHTML.attribute("content") == ["0123456789abcdef"]
  end

  @tag :tmp_dir
  test "keeps naming the release it read first after the release file changes", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "sw_release.json")
    File.write!(path, GobusgoWeb.ServiceWorker.release_file("0123456789abcdef"))
    Application.put_env(:gobusgo, :service_worker_release_file, path)
    first = release_meta() |> LazyHTML.attribute("content")
    File.write!(path, GobusgoWeb.ServiceWorker.release_file("fedcba9876543210"))

    assert first == ["0123456789abcdef"]
    assert release_meta() |> LazyHTML.attribute("content") == ["0123456789abcdef"]
  end

  @tag :tmp_dir
  test "has no release meta element where no service worker has been built", %{tmp_dir: tmp_dir} do
    Application.put_env(:gobusgo, :service_worker_release_file, Path.join(tmp_dir, "absent.json"))

    assert Enum.empty?(release_meta())
  end

  @tag :tmp_dir
  test "has no release meta element for a malformed release file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "sw_release.json")
    File.write!(path, "release")
    Application.put_env(:gobusgo, :service_worker_release_file, path)

    assert Enum.empty?(release_meta())
  end

  test "names the time the page was rendered in a rendered-at meta element" do
    before = DateTime.utc_now()
    [content] = head(~s(meta[name="gobusgo:rendered-at"])) |> LazyHTML.attribute("content")
    {:ok, rendered_at, 0} = DateTime.from_iso8601(content)

    assert DateTime.compare(rendered_at, DateTime.truncate(before, :millisecond)) in [:eq, :gt]
    assert DateTime.compare(rendered_at, DateTime.utc_now()) in [:eq, :lt]
  end

  test "writes the render time in UTC to the millisecond, as the browser's Date.parse reads it" do
    [content] = head(~s(meta[name="gobusgo:rendered-at"])) |> LazyHTML.attribute("content")

    assert content =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
  end

  test "sets the theme from the stored setting in a script that runs before the stylesheet" do
    children = head("> *") |> Enum.map(&LazyHTML.tag/1) |> List.flatten()
    script_index = Enum.find_index(children, &(&1 == "script"))
    stylesheet_index = Enum.find_index(children, &(&1 == "link"))
    [script] = head("script:not([src])") |> Enum.map(&LazyHTML.text/1)

    assert script_index < stylesheet_index
    assert script =~ "document.documentElement.dataset.theme"
  end

  test "reads the theme setting under the key and with the stored themes of the stored settings module" do
    %{"keys" => %{"theme" => key}, "storedThemes" => stored_themes} =
      "assets/js/stored_settings.json" |> File.read!() |> JSON.decode!()

    [script] = head("script:not([src])") |> Enum.map(&LazyHTML.text/1)

    assert script =~ ~s{localStorage.getItem(#{JSON.encode!(key)})}
    assert script =~ "var storedThemes = #{JSON.encode!(stored_themes)};"
    assert script =~ "storedThemes.indexOf(setting) !== -1"
  end

  test "loads the page's script as an ES module" do
    script = head(~s(script[src="/assets/js/app.js"]))

    assert LazyHTML.attribute(script, "type") == ["module"]
  end

  test "preloads the core's WebAssembly module for the fetch that compiles it" do
    preload = head(~s(link[rel="preload"][data-core-module]))

    assert LazyHTML.attribute(preload, "href") == ["/assets/core/gobusgo_core_bg.wasm"]
    assert LazyHTML.attribute(preload, "as") == ["fetch"]
    assert LazyHTML.attribute(preload, "type") == ["application/wasm"]
    assert LazyHTML.attribute(preload, "crossorigin") == []
  end

  test "links the web app manifest" do
    assert head(~s(link[rel="manifest"])) |> LazyHTML.attribute("href") == [
             "/manifest.webmanifest"
           ]
  end

  test "links the icon a home screen draws" do
    assert head(~s(link[rel="apple-touch-icon"])) |> LazyHTML.attribute("href") == [
             "/icons/apple-touch-icon.png"
           ]
  end

  test "names one theme color, for every color scheme" do
    theme_colors = head(~s(meta[name="theme-color"]))

    assert Enum.count(theme_colors) == 1
    assert LazyHTML.attribute(theme_colors, "media") == []
  end

  test "names the light theme's color before the script runs" do
    %{"light" => light} = "assets/js/theme_colors.json" |> File.read!() |> JSON.decode!()

    assert head(~s(meta[name="theme-color"])) |> LazyHTML.attribute("content") == [light]
  end

  test "sets the theme color of the resolved theme in the script, from the colors of the theme module" do
    theme_colors = "assets/js/theme_colors.json" |> File.read!() |> JSON.decode!()
    [script] = head("script:not([src])") |> Enum.map(&LazyHTML.text/1)

    assert script =~ "var themeColors = #{JSON.encode!(theme_colors)};"
    assert script =~ ~s{setAttribute("content", themeColors[theme])}
  end

  test "has a reload offer for a new release, hidden until the browser shows it" do
    offer = LazyHTML.from_document(html_response(get(build_conn(), "/"), 200))
    offer = LazyHTML.query(offer, "body #release-update[hidden] button[data-release-reload]")

    assert Enum.count(offer) == 1
  end

  test "has a message in the reload offer that the browser writes when a takeover is late" do
    document = LazyHTML.from_document(html_response(get(build_conn(), "/"), 200))
    message = LazyHTML.query(document, "body #release-update[hidden] [data-release-message]")

    assert Enum.count(message) == 1
  end
end
