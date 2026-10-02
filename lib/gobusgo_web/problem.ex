defmodule GobusgoWeb.Problem do
  @moduledoc """
  Sends a problem details response from a controller action. The body comes
  from `GobusgoWeb.ErrorJSON.problem/1`.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias GobusgoWeb.ErrorJSON

  @doc "Answers `problem.status` with the problem details for `problem`."
  @spec respond(Plug.Conn.t(), %{
          required(:status) => pos_integer(),
          optional(:detail) => String.t()
        }) ::
          Plug.Conn.t()
  def respond(conn, %{status: status} = problem) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.problem(problem))
  end
end
