defmodule GobusgoWeb.VehicleFilterForm do
  @route_query_param "route_query"
  @route_query_debounce_ms 200

  @moduledoc """
  The form a map page offers its vehicle filter with: one checkbox per
  agency, then a text box that narrows the routes and one checkbox per
  route.

  A change and a submit of the form send the `vehicle-filter:change` event
  with the checked agencies as `agency`, the checked routes as `route`, and
  the text as `#{@route_query_param}`, the text #{@route_query_debounce_ms} ms
  after the last key. The form mounts the `VehicleFilter` hook.
  """

  use Phoenix.Component

  alias GobusgoWeb.RouteOptions

  @doc "The name of the form's parameter that holds the text of the text box."
  @spec route_query_param() :: String.t()
  def route_query_param, do: @route_query_param

  @doc """
  The form. `agency_options` are the options of `GobusgoWeb.AgencyOptions`,
  `route_options` those of `GobusgoWeb.RouteOptions`, `route_query` the text
  of the text box, and `supplied` whether the page's address supplies a
  filter.
  """
  attr :agency_options, :list, required: true
  attr :route_options, :map, required: true
  attr :route_query, :string, required: true
  attr :supplied, :boolean, required: true

  def form(assigns) do
    ~H"""
    <form
      id="vehicle-filter"
      phx-hook="VehicleFilter"
      phx-change="vehicle-filter:change"
      phx-submit="vehicle-filter:change"
      data-supplied={to_string(@supplied)}
      class="text-sm"
    >
      <.agencies options={@agency_options} />
      <.routes options={@route_options} query={@route_query} />
    </form>
    """
  end

  attr :options, :list, required: true

  defp agencies(assigns) do
    ~H"""
    <details id="vehicle-filter-agencies">
      <summary class="cursor-pointer font-medium">Agencies</summary>
      <div class="mt-2 flex max-h-[60vh] flex-col gap-1 overflow-y-auto">
        <label :for={option <- @options} class="flex items-center gap-2">
          <input type="checkbox" name="agency[]" value={option.id} checked={option.checked} />
          <span>{option.name}</span>
        </label>
      </div>
    </details>
    """
  end

  attr :options, :map, required: true
  attr :query, :string, required: true

  defp routes(assigns) do
    assigns =
      assign(assigns,
        query_param: @route_query_param,
        query_debounce_ms: @route_query_debounce_ms,
        query_length_max: RouteOptions.query_length_max()
      )

    ~H"""
    <details id="vehicle-filter-routes" class="mt-2">
      <summary class="cursor-pointer font-medium">Routes</summary>
      <input
        type="search"
        name={@query_param}
        value={@query}
        placeholder="Route name"
        aria-label="Narrow the routes by name"
        maxlength={@query_length_max}
        autocomplete="off"
        phx-debounce={@query_debounce_ms}
        class="mt-2 w-full rounded-md border border-gray-300 bg-white px-2 py-1"
      />
      <div class="mt-2 flex max-h-[40vh] flex-col gap-1 overflow-y-auto">
        <label
          :for={option <- @options.selected ++ @options.matches}
          class="flex items-baseline gap-2"
        >
          <input type="checkbox" name="route[]" value={option.id} checked={option.checked} />
          <span class="font-medium">{option.name}</span>
          <span :if={option.detail != nil}>{option.detail}</span>
          <span :if={option.agency_name != nil} class="text-gray-600">
            {option.agency_name}
          </span>
        </label>
        <p :if={@options.rest_count > 0} id="vehicle-filter-routes-rest" class="text-gray-600">
          {@options.rest_count} more
        </p>
      </div>
    </details>
    """
  end
end
