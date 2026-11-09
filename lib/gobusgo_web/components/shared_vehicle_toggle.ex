defmodule GobusgoWeb.SharedVehicleToggle do
  @show_event "shared-vehicles:show"
  @hide_event "shared-vehicles:hide"

  @moduledoc """
  The control in a map page's Filter tab that turns the shared scooter and
  bike layer on and off, with a legend of the form factors' colors and a
  line that says what the layer shows.

  The checkbox mounts the `SharedVehicleToggle` hook, which sends
  `#{@show_event}` when the rider checks it and `#{@hide_event}` when the
  rider clears it, keeps the rider's choice in the browser, and sends
  `#{@show_event}` on mount where the browser keeps the layer on. The
  server renders the checkbox as the page holds the layer. While the page
  is offline the hook disables the checkbox, and the stylesheet shows the
  note that scooters and bikes need a connection.
  """

  use Phoenix.Component

  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.VehicleLive.SharedVehicles

  @doc """
  The control. `shown` is whether the page holds the layer on, and `status`
  what the page says of it, `nil` while it is off.
  """
  attr :shown, :boolean, required: true
  attr :status, :atom, required: true

  def toggle(assigns) do
    assigns =
      assign(assigns,
        form_colors: SharedVehicles.form_colors(),
        show_event: @show_event,
        hide_event: @hide_event
      )

    ~H"""
    <section
      id="shared-vehicles"
      phx-hook="SharedVehicleToggle"
      data-show-event={@show_event}
      data-hide-event={@hide_event}
      aria-labelledby="shared-vehicles-label"
      class="mt-4 flex flex-col gap-2 text-sm"
    >
      <label id="shared-vehicles-label" class="flex items-center gap-2 font-medium">
        <input id="shared-vehicles-shown" type="checkbox" checked={@shown} />
        Show shared scooters and bikes
      </label>
      <p class="offline-note">{AppInfo.needs_connection(:shared_vehicles)}</p>
      <ul
        :if={@shown}
        id="shared-vehicles-legend"
        class="needs-connection flex flex-wrap gap-x-3 gap-y-1"
      >
        <li :for={form <- @form_colors} class="flex items-center gap-1">
          <span
            class="shared-vehicle-swatch"
            data-form-factor={form.form_factor}
            style={"background-color: #{form.color}"}
            aria-hidden="true"
          >
            {form.letter}
          </span>
          {form.label}
        </li>
        <li id="shared-vehicles-low-range" class="flex items-center gap-1">
          <span
            class="shared-vehicle-swatch shared-vehicle-swatch-low"
            style={"--swatch-color: #{hd(@form_colors).color}"}
            aria-hidden="true"
          >
            {hd(@form_colors).letter}
          </span>
          Low range: the upper half is white
        </li>
      </ul>
      <p
        :if={@status != nil}
        id="shared-vehicles-status"
        class="needs-connection"
        data-status={@status}
        aria-live="polite"
      >
        {SharedVehicles.status_text(@status)}
      </p>
    </section>
    """
  end
end
