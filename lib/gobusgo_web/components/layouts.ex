defmodule GobusgoWeb.Layouts do
  @moduledoc """
  The layouts browser pages render inside. `root/1` is the HTML document:
  the head with the CSRF token, the commit the application was built from
  where the build names one, and the built assets, and the page as the body.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias GobusgoWeb.Endpoint

  @doc "The HTML document around the page in `assigns.inner_content`."
  attr :inner_content, :any, required: true

  def root(assigns) do
    {:ok, revision} = Gobusgo.Config.revision()
    assigns = assign(assigns, revision: revision)

    # `revision` is the WHATWG MetaExtensions name for the revision a version
    # control system reports.
    # https://wiki.whatwg.org/wiki/MetaExtensions — checked 2026-10-15
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta :if={@revision} name="revision" content={@revision} />
        <title>Gobusgo</title>
        <link phx-track-static rel="stylesheet" href={Endpoint.static_path("/assets/css/app.css")} />
        <script
          defer
          phx-track-static
          type="text/javascript"
          src={Endpoint.static_path("/assets/js/app.js")}
        >
        </script>
      </head>
      <body class="bg-white text-slate-900">
        {@inner_content}
      </body>
    </html>
    """
  end
end
