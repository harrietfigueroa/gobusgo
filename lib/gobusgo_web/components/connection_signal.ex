defmodule GobusgoWeb.ConnectionSignal do
  @section_id "app-info-offline"
  @announcer_id "connection-announcement"

  @moduledoc """
  The markup of a page's connection state, which the browser decides:
  `state_hook/1`, the element of the `ConnectionState` hook, whose join and
  lost socket are the state's authority, and `signal/1`, the offline signal
  of a map page and the polite live region that announces going offline
  and coming back.

  The signal is a button the `ConnectionSignal` hook writes and the server
  leaves alone, with an icon beside its text. The stylesheet shows it while
  the page is offline, and a click opens the Settings tab's offline
  section, `##{@section_id}`.
  """

  use Phoenix.Component

  @doc "The identifier of the Settings tab's offline section, which the signal opens."
  @spec section_id() :: String.t()
  def section_id, do: @section_id

  @doc "The element of the `ConnectionState` hook, which shows nothing."
  def state_hook(assigns) do
    ~H"""
    <div id="connection-state" phx-hook="ConnectionState" hidden></div>
    """
  end

  @doc "The offline signal over a map, and its live region."
  def signal(assigns) do
    assigns = assign(assigns, section_id: @section_id, announcer_id: @announcer_id)

    ~H"""
    <button
      id="connection-signal"
      type="button"
      class="connection-signal surface"
      phx-hook="ConnectionSignal"
      phx-update="ignore"
      data-section-id={@section_id}
      data-announcer-id={@announcer_id}
    >
      <svg aria-hidden="true" class="connection-signal-icon" viewBox="0 0 24 24">
        <path d="M7 18 H17 A4 4 0 0 0 17.5 10 A6 6 0 0 0 6.2 9.5 A4.3 4.3 0 0 0 7 18 Z" />
        <path d="M3 3 L21 21" />
      </svg>
      <span class="connection-signal-text">
        <span data-signal-title>Offline</span>
        <span data-signal-age class="connection-signal-age" hidden></span>
      </span>
    </button>
    <p id={@announcer_id} class="sr-only" role="status" aria-live="polite" phx-update="ignore"></p>
    """
  end
end
