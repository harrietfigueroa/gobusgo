defmodule GobusgoWeb.Layouts do
  @moduledoc """
  The layouts browser pages render inside. `root/1` is the HTML document:
  the head with the CSRF token, the page's title, the commit the application was built from
  where the build names one, the time the page was rendered, which tells
  the browser a copy from a cache, the web app manifest, the icon a home screen
  draws, the theme color, the script that draws the page and sets that
  color in the rider's theme, and the built assets, and the page as the body
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

  # The content of the theme-color meta element per theme, each theme's page
  # background, read from the theme colors file when this module is compiled.
  @theme_colors_path Path.expand("../../../assets/js/theme_colors.json", __DIR__)
  @external_resource @theme_colors_path

  @theme_colors @theme_colors_path |> File.read!() |> JSON.decode!()
  @theme_color_light Map.fetch!(@theme_colors, "light")

  # Runs before the stylesheet applies, so the first paint and the browser's
  # bars are in the theme the rider's setting resolves to: a stored theme as
  # stored, and with any other stored value, no stored value, or storage that
  # throws, the system's preference.
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
    var themeColors = #{JSON.encode!(@theme_colors)};
    document.querySelector('meta[name="theme-color"]').setAttribute("content", themeColors[theme]);
  })();
  """

  @doc "The HTML document around the page in `assigns.inner_content`."
  attr :inner_content, :any, required: true

  def root(assigns) do
    {:ok, revision} = Gobusgo.Config.revision()

    assigns =
      assign(assigns,
        revision: revision,
        rendered_at:
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        theme_script: @theme_script,
        theme_color_light: @theme_color_light,
        title_suffix: title_suffix(assigns[:page_title])
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
        <meta name="gobusgo:rendered-at" content={@rendered_at} />
        <.live_title default="Gobusgo" suffix={@title_suffix}>{assigns[:page_title]}</.live_title>
        <meta name="theme-color" content={@theme_color_light} />
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
          <p data-release-message>A new version of Gobusgo is ready.</p>
          <button type="button" class="font-semibold underline" data-release-reload>Reload</button>
        </div>
      </body>
    </html>
    """
  end

  # A page that names itself in `page_title` is titled "<name> · Gobusgo";
  # one that names nothing is titled "Gobusgo" alone.
  defp title_suffix(nil), do: nil
  defp title_suffix(page_title) when is_binary(page_title), do: " · Gobusgo"
end
