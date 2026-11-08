defmodule GobusgoWeb.Layouts do
  @moduledoc """
  The layouts browser pages render inside. `root/1` is the HTML document:
  the head with the CSRF token, the commit the application was built from
  where the build names one, the script that draws the page in the rider's
  theme, and the built assets, and the page as the body.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias GobusgoWeb.Endpoint

  @theme_setting_key "gobusgo:theme"

  # Runs before the stylesheet applies, so the first paint is in the theme
  # the rider's setting resolves to: "light" or "dark" as stored, and with
  # no stored value, or storage that throws, the system's preference.
  @theme_script """
  (function () {
    var setting = null;
    try {
      setting = window.localStorage.getItem("#{@theme_setting_key}");
    } catch (error) {
      setting = null;
    }
    var systemDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    var isSystemDark = setting !== "light" && systemDark;
    var theme = "light";
    if (setting === "dark") {
      theme = "dark";
    } else if (isSystemDark) {
      theme = "dark";
    }
    document.documentElement.dataset.theme = theme;
  })();
  """

  @doc "The local storage key that holds the rider's theme setting."
  @spec theme_setting_key() :: String.t()
  def theme_setting_key, do: @theme_setting_key

  @doc "The HTML document around the page in `assigns.inner_content`."
  attr :inner_content, :any, required: true

  def root(assigns) do
    {:ok, revision} = Gobusgo.Config.revision()
    assigns = assign(assigns, revision: revision, theme_script: @theme_script)

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
        <script>
          <%= Phoenix.HTML.raw(@theme_script) %>
        </script>
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
