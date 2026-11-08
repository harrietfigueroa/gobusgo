defmodule GobusgoWeb.PanelSheet do
  @moduledoc """
  The panel sheet of a map page: a row of tabs, each controlling one panel,
  under a handle and a summary line. Below the `md` breakpoint it is a sheet
  along the bottom of the viewport, collapsed to its handle, its summary, and
  its tabs, and expanded with the panel of the open tab; from that
  breakpoint up it is a panel along the left side, always expanded.

  The `PanelSheet` hook opens the tabs, expands and collapses the sheet, and
  holds that state in the browser: no tab and no drag sends the server an
  event. The server renders the first tab open and the sheet collapsed, and
  every attribute that carries that state is one a patch leaves as the
  browser has it, so a patch of the page keeps the tab a rider opened.

  Every panel is rendered whichever tab is open, so a hook inside a panel
  mounts once with the page and keeps running while its tab is closed.

  With `detail`, the sheet also holds a details view, rendered hidden, which
  the browser shows in place of the tabs and their panels and writes the
  content of; its back button hides it again and so returns to the tab that
  was open. Whether it is shown and what it holds are the browser's, across
  patches as well.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  The sheet. Each `tab` is one tab and its panel, in display order: `name`
  names it in the identifiers `panel-tab-<name>` of the tab and
  `panel-<name>` of the panel, `label` is its visible text, and
  `accessible_label`, where given, its accessible name in place of its
  text. `badge`, where given, is a text the tab shows beside its label, and
  `browser_badge_id`, where given, the identifier of an empty badge whose
  content a patch leaves to the browser. `summary` is the line above the
  tabs. `detail` adds the details view.
  """
  attr :detail, :boolean, default: false

  slot :summary

  slot :tab, required: true do
    attr :name, :string, required: true
    attr :label, :string, required: true
    attr :accessible_label, :string
    attr :badge, :string
    attr :browser_badge_id, :string
  end

  def sheet(assigns) do
    [%{name: selected} | _rest] = assigns.tab
    assigns = assign(assigns, selected: selected)

    ~H"""
    <section
      id="panel-sheet"
      phx-hook="PanelSheet"
      aria-label="Panels"
      data-expanded="false"
      phx-mounted={JS.ignore_attributes(["data-expanded"])}
      class="panel-sheet"
    >
      <button
        id="panel-sheet-handle"
        type="button"
        class="panel-sheet-handle"
        aria-controls="panel-sheet-body"
        aria-expanded="false"
        aria-label="Expand the panels"
        phx-mounted={JS.ignore_attributes(["aria-expanded", "aria-label"])}
      >
        <span class="panel-sheet-grip" aria-hidden="true"></span>
      </button>

      <div :if={@summary != []} id="panel-sheet-summary" class="panel-sheet-summary">
        {render_slot(@summary)}
      </div>

      <div role="tablist" aria-label="Panels" class="panel-sheet-tabs">
        <button
          :for={tab <- @tab}
          id={"panel-tab-" <> tab.name}
          type="button"
          role="tab"
          class="panel-sheet-tab"
          aria-controls={"panel-" <> tab.name}
          aria-selected={to_string(tab.name == @selected)}
          aria-label={Map.get(tab, :accessible_label)}
          tabindex={tabindex(tab.name == @selected)}
          phx-mounted={JS.ignore_attributes(["aria-selected", "tabindex"])}
        >
          <.icon name={tab.name} />
          <span data-tab-label>{tab.label}</span>
          <span
            :if={Map.get(tab, :badge) != nil}
            id={"panel-tab-" <> tab.name <> "-badge"}
            class="panel-sheet-badge"
            aria-hidden="true"
          >
            {tab.badge}
          </span>
          <span
            :if={Map.get(tab, :browser_badge_id) != nil}
            id={tab.browser_badge_id}
            class="panel-sheet-badge"
            phx-update="ignore"
            hidden
          ></span>
        </button>
      </div>

      <div id="panel-sheet-body" class="panel-sheet-body">
        <div
          :for={tab <- @tab}
          id={"panel-" <> tab.name}
          role="tabpanel"
          aria-labelledby={"panel-tab-" <> tab.name}
          tabindex="0"
          hidden={tab.name != @selected}
          phx-mounted={JS.ignore_attributes(["hidden"])}
          class="panel-sheet-panel"
        >
          {render_slot(tab)}
        </div>
      </div>

      <section
        :if={@detail}
        id="panel-detail"
        class="panel-sheet-detail"
        aria-labelledby="panel-detail-title"
        hidden
        phx-mounted={JS.ignore_attributes(["hidden"])}
      >
        <button
          id="panel-detail-back"
          type="button"
          class="panel-sheet-back"
          aria-label="Back"
          phx-mounted={JS.ignore_attributes(["aria-label"])}
        >
          <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
            <path d="M20 12 H5 M11 6 L5 12 L11 18" />
          </svg>
        </button>
        <div id="panel-detail-content" class="panel-sheet-detail-content" phx-update="ignore"></div>
      </section>
    </section>
    """
  end

  # The open tab is the one a keyboard reaches; the arrow keys move among
  # the others.
  defp tabindex(true), do: "0"
  defp tabindex(false), do: "-1"

  attr :name, :string, required: true

  defp icon(%{name: "trip"} = assigns) do
    ~H"""
    <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
      <circle cx="6" cy="18" r="2" /><circle cx="18" cy="6" r="2" />
      <path d="M8 18 H14 A4 4 0 0 0 14 10 H10 A4 4 0 0 1 10 2 H16" />
    </svg>
    """
  end

  defp icon(%{name: "favorites"} = assigns) do
    ~H"""
    <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
      <path d="M12 3 L14.8 9 L21 9.6 L16.3 13.8 L17.7 20 L12 16.8 L6.3 20 L7.7 13.8 L3 9.6 L9.2 9 Z" />
    </svg>
    """
  end

  defp icon(%{name: "filter"} = assigns) do
    ~H"""
    <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
      <path d="M3 5 H21 L14 13 V19 L10 21 V13 Z" />
    </svg>
    """
  end

  defp icon(%{name: "alerts"} = assigns) do
    ~H"""
    <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
      <path d="M12 3 L22 20 H2 Z" /><path d="M12 10 V14 M12 17 V17.5" />
    </svg>
    """
  end

  defp icon(%{name: "settings"} = assigns) do
    ~H"""
    <svg aria-hidden="true" class="panel-sheet-icon" viewBox="0 0 24 24">
      <path d="M4 6 H7 M11 6 H20 M4 12 H13 M17 12 H20 M4 18 H5 M9 18 H20" />
      <circle cx="9" cy="6" r="2" /><circle cx="15" cy="12" r="2" /><circle cx="7" cy="18" r="2" />
    </svg>
    """
  end
end
