defmodule GobusgoWeb.ConnectionSignal do
  @setting_id "offline-use-enabled"
  @announcer_id "connection-announcement"

  @moduledoc """
  The markup of a page's connection state, which the browser decides:
  `state_hook/1`, the element of the `ConnectionState` hook, whose join and
  lost socket are the state's authority, and `signal/1`, the offline signal
  of a map page and the polite live region that announces going offline
  and coming back.

  The signal is a button the `ConnectionSignal` hook writes and the server
  leaves alone, with an icon before its text and a chevron after it. The
  stylesheet shows it while the page is offline, and a click opens the
  Settings tab at the Save for offline use setting, `##{@setting_id}`, and
  moves focus to it.
  """

  use Phoenix.Component

  @doc "The identifier of the Save for offline use checkbox, which the signal opens."
  @spec setting_id() :: String.t()
  def setting_id, do: @setting_id

  @doc "The element of the `ConnectionState` hook, which shows nothing."
  def state_hook(assigns) do
    ~H"""
    <div id="connection-state" phx-hook="ConnectionState" hidden></div>
    """
  end

  @doc "The offline signal over a map, and its live region."
  def signal(assigns) do
    assigns = assign(assigns, setting_id: @setting_id, announcer_id: @announcer_id)

    ~H"""
    <button
      id="connection-signal"
      type="button"
      class="connection-signal surface"
      phx-hook="ConnectionSignal"
      phx-update="ignore"
      data-setting-id={@setting_id}
      data-announcer-id={@announcer_id}
    >
      <svg aria-hidden="true" class="connection-signal-icon" viewBox="0 0 24 24">
        <path d="M7 18 H17 A4 4 0 0 0 17.5 10 A6 6 0 0 0 6.2 9.5 A4.3 4.3 0 0 0 7 18 Z" />
        <path d="M3 3 L21 21" />
      </svg>
      <span class="connection-signal-text">
        <span data-signal-headline class="message-headline">Offline</span>
        <span data-signal-caption class="connection-signal-caption" hidden></span>
      </span>
      <svg aria-hidden="true" class="connection-signal-chevron" viewBox="0 0 24 24">
        <path d="M9 6 L15 12 L9 18" />
      </svg>
    </button>
    <p id={@announcer_id} class="sr-only" role="status" aria-live="polite" phx-update="ignore"></p>
    """
  end
end
