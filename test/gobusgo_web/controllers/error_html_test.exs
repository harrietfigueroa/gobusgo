defmodule GobusgoWeb.ErrorHTMLTest do
  # Renders the error page for a status and checks the HTML document it
  # produces.
  use ExUnit.Case, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a document that names the status and its reason phrase" do
    html = render_to_string(GobusgoWeb.ErrorHTML, "500", "html", status: 500)

    assert html =~ "<title>500 Internal Server Error</title>"
    assert html =~ "<h1>500 Internal Server Error</h1>"
  end
end
