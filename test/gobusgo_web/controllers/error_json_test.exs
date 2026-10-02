defmodule GobusgoWeb.ErrorJSONTest do
  # Verifies the problem details as a pure function of the status and the
  # error, with expected objects written out by hand.
  use ExUnit.Case, async: true

  alias GobusgoWeb.ErrorJSON

  describe "render/2" do
    test "names the status and its reason phrase" do
      assert ErrorJSON.render("503.json", %{status: 503, reason: %RuntimeError{message: "x"}}) ==
               %{"type" => "about:blank", "title" => "Service Unavailable", "status" => 503}
    end

    test "leaves the message of an unexpected error out" do
      error = %RuntimeError{message: "connection string with a password"}

      assert ErrorJSON.render("500.json", %{status: 500, reason: error}) ==
               %{"type" => "about:blank", "title" => "Internal Server Error", "status" => 500}
    end

    test "names the method and path no route matches" do
      error = %Phoenix.Router.NoRouteError{
        conn: %Plug.Conn{method: "GET", request_path: "/nope"},
        router: GobusgoWeb.Router
      }

      assert ErrorJSON.render("404.json", %{status: 404, reason: error}) == %{
               "type" => "about:blank",
               "title" => "Not Found",
               "status" => 404,
               "detail" => "No route matches GET /nope."
             }
    end
  end
end
