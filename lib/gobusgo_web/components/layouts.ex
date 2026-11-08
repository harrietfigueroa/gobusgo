defmodule GobusgoWeb.Layouts do
  @moduledoc """
  The layouts browser pages render inside. `root/1` is the HTML document:
  the head with the CSRF token, the commit the application was built from
  where the build names one, the web app manifest, the icon a home screen
  draws, the theme color of each color scheme, the script that draws the
  page in the rider's theme, and the built assets, and the page as the body
  with the offer to reload into a new release.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias GobusgoWeb.Endpoint

  # The key and the stored themes are those of assets/js/stored_settings.js,
  # which reads them from the same file, read when this module is compiled.
  @stored_settings_path Path.expand("../../../assets/js/stored_settings.json", __DIR__)
  @external_resource @stored_settings_path

  %{"keys" => %{"theme" => theme_setting_key}, "storedThemes" => stored_themes} =
    @stored_settings_path |> File.read!() |> JSON.decode!()

  @theme_setting_key theme_setting_key
  @stored_themes stored_themes
  # The page backgrounds of the light and the dark theme in assets/css/app.css.
  @theme_color_light "#ffffff"
  @theme_color_dark "#0f172a"

  # Runs before the stylesheet applies, so the first paint is in the theme
  # the rider's setting resolves to: a stored theme as stored, and with any
  # other stored value, no stored value, or storage that throws, the
  # system's preference.
  @theme_script """
  (function () {
    var setting = null;
    try {
      setting = window.localStorage.getItem(#{JSON.encode!(@theme_setting_key)});
    } catch (error) {
      setting = null;
    }
    var storedThemes = #{JSON.encode!(@stored_themes)};
    var systemDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    var theme = "light";
    if (storedThemes.indexOf(setting) !== -1) {
      theme = setting;
    } else if (systemDark) {
      theme = "dark";
    }
    document.documentElement.dataset.theme = theme;
  })();
  """

  @doc "The HTML document around the page in `assigns.inner_content`."
  attr :inner_content, :any, required: true

  def root(assigns) do
    {:ok, revision} = Gobusgo.Config.revision()

    assigns =
      assign(assigns,
        revision: revision,
        theme_script: @theme_script,
        theme_color_light: @theme_color_light,
        theme_color_dark: @theme_color_dark
      )

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
        <meta
          name="theme-color"
          media="(prefers-color-scheme: light)"
          content={@theme_color_light}
        />
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content={@theme_color_dark} />
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
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="apple-touch-icon" href="/icons/apple-touch-icon.png" />
      </head>
      <body class="bg-white text-slate-900">
        {@inner_content}
        <div
          id="release-update"
          class="surface fixed bottom-4 left-1/2 z-50 flex -translate-x-1/2 items-center gap-3 px-4 py-2"
          role="status"
          hidden
        >
          <p>A new version of Gobusgo is ready.</p>
          <button type="button" class="font-semibold underline" data-release-reload>Reload</button>
        </div>
      </body>
    </html>
    """
  end
end
