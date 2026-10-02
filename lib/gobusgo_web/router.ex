defmodule GobusgoWeb.Router do
  @moduledoc """
  The routes of the HTTP API. Every route answers JSON; a request no route
  matches, or one that accepts no JSON, is answered by
  `GobusgoWeb.ErrorJSON`.
  """

  use Phoenix.Router

  import Phoenix.Controller, only: [accepts: 2]

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GobusgoWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api", GobusgoWeb do
    pipe_through :api

    get "/agencies", AgencyController, :index
    get "/agencies/:id", AgencyController, :show
  end
end
