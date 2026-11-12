defmodule GobusgoWeb.Mcp.ArrivalsBoardDocument do
  @moduledoc """
  The HTML document of the arrivals board app, written from the origin its
  files are served from and the addresses of its bundle and stylesheet.
  Everything here is pure.

  The document holds no script of its own: it loads the one bundle and the
  one stylesheet from the origin. The credit is text the server writes, from
  `GobusgoWeb.AppInfo`, the source the Settings tab reads it from.
  """

  alias GobusgoWeb.AppInfo

  @title "Arrivals board"

  @doc "The title of the document, which names no agency."
  @spec title() :: String.t()
  def title, do: @title

  @doc """
  The document for `files`: `origin`, the scheme and host the files are
  served from, `script_path`, and `stylesheet_path`, each a path that begins
  with a slash.
  """
  @spec render(%{origin: String.t(), script_path: String.t(), stylesheet_path: String.t()}) ::
          String.t()
  def render(%{origin: origin, script_path: script_path, stylesheet_path: stylesheet_path}) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{escape(@title)}</title>
    <link rel="stylesheet" href="#{escape(origin <> stylesheet_path)}">
    <script defer src="#{escape(origin <> script_path)}"></script>
    </head>
    <body class="bg-white text-slate-900">
    <main id="mcp-arrivals-board" class="mcp-trip-app">
    <noscript><p>The arrivals board needs scripts.</p></noscript>
    </main>
    <footer class="mcp-trip-credits">
    #{credit()}
    </footer>
    </body>
    </html>
    """
  end

  defp credit do
    %{lead: lead, trail: trail} = AppInfo.provision()
    %{name: terms_name, url: terms_url} = AppInfo.terms()

    ~s(<p>#{escape(lead)}#{escape(AppInfo.agencies_credit([]))}, under the ) <>
      ~s(<a class="inline-target" href="#{escape(terms_url)}" target="_blank" rel="noopener noreferrer">#{escape(terms_name)}</a> #{escape(trail)}</p>)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
