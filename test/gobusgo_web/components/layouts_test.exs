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

  defp revision_meta do
    build_conn()
    |> get("/")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(head meta[name="revision"]))
  end

  test "names the commit the application was built from in a revision meta element" do
    Application.put_env(:gobusgo, :revision, revision: @revision)

    assert revision_meta() |> LazyHTML.attribute("content") == [@revision]
  end

  test "has no revision meta element for an application built without a commit" do
    Application.put_env(:gobusgo, :revision, revision: nil)

    assert Enum.empty?(revision_meta())
  end
end
