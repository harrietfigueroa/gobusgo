defmodule GobusgoWeb.ErrorHTML do
  @moduledoc """
  The body of an error response a browser asked for: a document that names
  the status and its reason phrase, and nothing about the error itself.
  """

  use Phoenix.Component

  @doc """
  Returns the page for `assigns.status`. `template` names the status and
  the format, such as `"404.html"`.
  """
  def render(template, %{status: status}) when is_binary(template) and is_integer(status) do
    assigns = %{title: "#{status} #{Plug.Conn.Status.reason_phrase(status)}", __changed__: nil}

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
      </head>
      <body>
        <main>
          <h1>{@title}</h1>
        </main>
      </body>
    </html>
    """
  end
end
