defmodule GobusgoWeb.ErrorJSON do
  @moduledoc """
  The body of every error response: a problem details object. Everything
  here is pure.

  The object holds `type`, always `about:blank`; `title`, the reason phrase
  of the status; and `status`. `detail` is present only for an error whose
  explanation is written here, so the message of an unexpected error never
  reaches a client.
  """

  alias Phoenix.Router.NoRouteError

  # With `about:blank` the title is the HTTP reason phrase.
  # https://www.rfc-editor.org/rfc/rfc9457#section-4.2.1 — checked 2026-10-02
  @type_default "about:blank"

  @doc """
  Returns the problem details for `assigns.status` and the error
  `assigns.reason`. `template` names the status and the format, such as
  `"404.json"`.
  """
  @spec render(String.t(), %{status: pos_integer(), reason: Exception.t()}) ::
          %{String.t() => term()}
  def render(template, %{status: status, reason: reason})
      when is_binary(template) and is_integer(status) do
    problem = %{
      "type" => @type_default,
      "title" => Plug.Conn.Status.reason_phrase(status),
      "status" => status
    }

    case detail(reason) do
      nil -> problem
      detail -> Map.put(problem, "detail", detail)
    end
  end

  defp detail(%NoRouteError{conn: %Plug.Conn{method: method, request_path: path}}) do
    "No route matches #{method} #{path}."
  end

  defp detail(_reason), do: nil
end
