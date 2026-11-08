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
  server renders the checkbox as the page holds the layer.
  """

  use Phoenix.Component

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
      <ul :if={@shown} id="shared-vehicles-legend" class="flex flex-wrap gap-x-3 gap-y-1">
        <li :for={form <- @form_colors} class="flex items-center gap-1">
          <span
            class="inline-block h-3 w-3 rounded-full"
            style={"background-color: #{form.color}"}
            aria-hidden="true"
          ></span>
          {form.label}
        </li>
      </ul>
      <p :if={@status != nil} id="shared-vehicles-status" data-status={@status} aria-live="polite">
        {SharedVehicles.status_text(@status)}
      </p>
    </section>
    """
  end
end
