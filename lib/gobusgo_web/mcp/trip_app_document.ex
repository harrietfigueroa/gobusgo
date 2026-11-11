defmodule GobusgoWeb.Mcp.TripAppDocument do
  @moduledoc """
  The HTML document of the trip planner app, written from the origin its
  files are served from, the addresses of its bundle and stylesheet, and the
  credits the data carries. Everything here is pure.

  The document holds no script of its own: it loads the one bundle and the
  one stylesheet from the origin, and names the origin in `data-file-origin`
  so the bundle fetches the routing, places, address, and intersection files
  from the same place. The credits are text the server writes, from
  `GobusgoWeb.AppInfo`, the source the Settings tab reads them from.
  """

  alias GobusgoWeb.AppInfo

  @title "Trip planner"

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
    <body class="bg-white text-slate-900" data-file-origin="#{escape(origin)}">
    <main id="mcp-trip-app" class="mcp-trip-app">
    <noscript><p>The trip planner needs scripts.</p></noscript>
    </main>
    <footer class="mcp-trip-credits">
    #{credits()}
    </footer>
    </body>
    </html>
    """
  end

  defp credits do
    %{lead: lead, trail: trail} = AppInfo.provision()
    %{name: terms_name, url: terms_url} = AppInfo.terms()
    intersections = AppInfo.intersection_source()
    places = AppInfo.places_license()

    Enum.join(
      [
        ~s(<p>#{escape(lead)}#{escape(AppInfo.agencies_credit([]))}, under the ) <>
          ~s(#{link(terms_name, terms_url)} #{escape(trail)}</p>),
        ~s(<p>Places and street intersections © #{escape(intersections.credit)}, under the ) <>
          ~s(#{link(intersections.license.name, intersections.license.url)}. ) <>
          ~s(#{link("OpenStreetMap copyright", copyright_url(places))}</p>),
        ~s(<p>Street addresses: #{address_credits()}</p>)
      ],
      "\n"
    )
  end

  defp copyright_url(%{links: links}) do
    %{url: url} = Enum.find(links, &(&1.text == "OpenStreetMap copyright"))
    url
  end

  defp address_credits do
    Enum.map_join(AppInfo.address_sources(), "; ", fn %{operator: operator, terms: terms} ->
      "#{escape(operator)}, #{link(terms.name, terms.url)}"
    end)
  end

  defp link(text, url) do
    ~s(<a class="inline-target" href="#{escape(url)}" target="_blank" rel="noopener noreferrer">#{escape(text)}</a>)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
