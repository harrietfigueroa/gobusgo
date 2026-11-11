defmodule GobusgoWeb.Router do
  @moduledoc """
  The routes of the application: browser pages, the health and readiness
  endpoints, the MCP endpoint at `/mcp`, and the JSON API under `/api`. Every browser page is in one live session whose
  mount hook, `GobusgoWeb.UsageHook`, registers the page's connection with
  the usage recorder. A request under `/api` that no route matches is
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

  pipeline :public_files do
    plug GobusgoWeb.PublicCors
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

    live_session :pages, on_mount: GobusgoWeb.UsageHook do
      live "/", HomeLive
      live "/agencies", AgencyLive
      live "/vehicles", VehicleLive
    end
  end

  scope "/", GobusgoWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/ready", ReadinessController, :show
    post "/mcp", McpController, :handle
    match :*, "/mcp", McpController, :method_not_allowed
  end

  scope "/api", GobusgoWeb do
    pipe_through :api

    get "/agencies", AgencyController, :index
    get "/agencies/:id", AgencyController, :show
  end

  # The manifests an MCP App reads from a sandbox of another origin, and the
  # public OpenAPI document.
  scope "/api", GobusgoWeb do
    pipe_through [:api, :public_files]

    get "/routing/manifest", RoutingManifestController, :show
    head "/routing/manifest", RoutingManifestController, :show
    get "/addresses/manifest", AddressManifestController, :show
    head "/addresses/manifest", AddressManifestController, :show
    get "/intersections/manifest", IntersectionManifestController, :show
    head "/intersections/manifest", IntersectionManifestController, :show
    get "/openapi.json", OpenApiController, :show
    head "/openapi.json", OpenApiController, :show
  end

  scope "/api", GobusgoWeb do
    pipe_through :api

    match :*, "/*path", FallbackController, :not_found
  end
end
