defmodule GobusgoWeb.LayoutsTest do
  # Requests a page through the endpoint with Phoenix.ConnTest and reads the
  # document's head, which the root layout renders around every page. The
  # commit is application configuration, global state, hence the non-async
  # case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint GobusgoWeb.Endpoint
  @revision "43402796c905c22db533043dee878950c74d5791"

  setup do
    configured = Application.get_env(:gobusgo, :revision)
    on_exit(fn -> Application.put_env(:gobusgo, :revision, configured) end)
  end

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

  test "names a theme color for a light and for a dark color scheme" do
    media = head(~s(meta[name="theme-color"])) |> LazyHTML.attribute("media")

    assert Enum.sort(media) == ["(prefers-color-scheme: dark)", "(prefers-color-scheme: light)"]
  end

  test "names the manifest's theme color for a light color scheme" do
    manifest = "priv/static/manifest.webmanifest" |> File.read!() |> JSON.decode!()
    light = head(~s{meta[name="theme-color"][media="(prefers-color-scheme: light)"]})

    assert LazyHTML.attribute(light, "content") == [manifest["theme_color"]]
  end

  test "has a reload offer for a new release, hidden until the browser shows it" do
    offer = LazyHTML.from_document(html_response(get(build_conn(), "/"), 200))
    offer = LazyHTML.query(offer, "body #release-update[hidden] button[data-release-reload]")

    assert Enum.count(offer) == 1
  end
end
