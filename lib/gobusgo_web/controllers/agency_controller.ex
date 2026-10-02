defmodule GobusgoWeb.AgencyController do
  @retry_after_seconds 5

  @moduledoc """
  Serves the agencies of the current fetch from
  `Gobusgo.OneBusAway.AgencyView`. Every response draws on one read of the
  view, so its agencies and its `meta` come from the same fetch.

  While the view has no current fetch, both actions answer `503` problem
  details with `Retry-After: #{@retry_after_seconds}`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Gobusgo.OneBusAway.AgencyView
  alias GobusgoWeb.AgencyJSON
  alias GobusgoWeb.Problem

  @doc "Answers `200` with every agency of the current fetch, in identifier order."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case AgencyView.current(AgencyView) do
      nil -> unavailable(conn)
      fetch -> json(conn, AgencyJSON.index(fetch))
    end
  end

  @doc """
  Answers `200` with the agency `id` of the current fetch, or `404` problem
  details when the fetch holds no such agency.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    case AgencyView.current(AgencyView) do
      nil ->
        unavailable(conn)

      %{agencies: %{^id => agency}} = fetch ->
        json(conn, AgencyJSON.show(%{agency: agency, fetch: fetch}))

      _fetch ->
        Problem.respond(conn, %{status: 404, detail: "No agency has the identifier #{id}."})
    end
  end

  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
    |> Problem.respond(%{status: 503, detail: "No agency fetch is available yet."})
  end
end
