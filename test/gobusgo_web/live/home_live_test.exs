defmodule GobusgoWeb.HomeLiveTest do
  # Requests the page through the endpoint twice over: as the plain HTTP
  # response a browser first receives, and as the connected LiveView that
  # Phoenix.LiveViewTest mounts over a test socket.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint GobusgoWeb.Endpoint

  describe "GET /" do
    test "answers 200 with the page inside the root layout" do
      html = build_conn() |> get("/") |> html_response(200)

      title = html |> LazyHTML.from_document() |> LazyHTML.query("head title") |> LazyHTML.text()
      assert title == "Gobusgo"
      assert html =~ ~s(<meta name="csrf-token")
      assert html =~ ~s(href="/assets/css/app.css")
      assert html =~ ~s(src="/assets/js/app.js")
      assert html =~ "The front end is running."
    end

    test "mounts as a connected LiveView" do
      {:ok, view, html} = live(build_conn(), "/")

      assert html =~ "The front end is running."
      assert render(view) =~ "The front end is running."
    end
  end
end
