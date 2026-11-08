defmodule GobusgoWeb.LayoutsTest do
  # Requests a page through the endpoint with Phoenix.ConnTest and reads the
  # document's head, which the root layout renders around every page. The
  # commit is application configuration, global state, hence the non-async
  # case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias GobusgoWeb.Layouts

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

  test "sets the theme from the stored setting in a script that runs before the stylesheet" do
    children = head("> *") |> Enum.map(&LazyHTML.tag/1) |> List.flatten()
    script_index = Enum.find_index(children, &(&1 == "script"))
    stylesheet_index = Enum.find_index(children, &(&1 == "link"))
    [script] = head("script:not([src])") |> Enum.map(&LazyHTML.text/1)

    assert script_index < stylesheet_index
    assert script =~ ~s{localStorage.getItem("#{Layouts.theme_setting_key()}")}
    assert script =~ "document.documentElement.dataset.theme"
  end

  test "reads the theme setting under the key the browser's hook stores it under" do
    hook = File.read!("assets/js/color_theme.js")

    assert hook =~ ~s(const SETTING_KEY = "#{Layouts.theme_setting_key()}")
  end
end
