defmodule GobusgoWeb.Router do
  @moduledoc """
  The routes of the application: browser pages, the health endpoint, and
  the JSON API under `/api`. A request under `/api` that no route matches is
  answered with problem details by `GobusgoWeb.FallbackController`. Any
  other request no route matches is answered by `GobusgoWeb.ErrorHTML` when
  it accepts HTML first, and by `GobusgoWeb.ErrorJSON` otherwise.
  """

  use Phoenix.Router

  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GobusgoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", GobusgoWeb do
    pipe_through :browser

    live "/", HomeLive
  end

  scope "/", GobusgoWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", GobusgoWeb do
    pipe_through :api

    get "/agencies", AgencyController, :index
    get "/agencies/:id", AgencyController, :show
    match :*, "/*path", FallbackController, :not_found
  end
end
