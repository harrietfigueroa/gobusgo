defmodule GobusgoWeb.VehicleFilterForm do
  @query_param "filter_query"
  @query_debounce_ms 200
  @add_event "vehicle-filter:add"
  @remove_event "vehicle-filter:remove"
  @query_event "vehicle-filter:query"

  @moduledoc """
  The form a map page offers its vehicle filter with: one text bar that
  holds a token per value of the filter, and under it a list of the
  suggestions the text narrows to, each labeled with its field. The bar
  follows the WAI-ARIA combobox pattern, its text box the combobox and the
  suggestions its listbox.

  A change and a submit of the form send the `#{@query_event}` event with
  the text as `#{@query_param}`, #{@query_debounce_ms} ms after the last key.
  A click on a suggestion sends `#{@add_event}` and a click on a token's
  remove button `#{@remove_event}`, each with the value's `field` and its
  `id`. A value is sent as `id`, because the click of a list item sends
  the item's own `value` property under `value`. The form mounts the
  `VehicleFilter` hook, and the bar the `FilterBar` hook, which moves
  through the suggestions from the keyboard.
  """

  use Phoenix.Component

  alias GobusgoWeb.RouteOptions

  @field_labels %{"agency" => "Agency", "route" => "Route"}

  @doc "The name of the form's parameter that holds the text of the text bar."
  @spec query_param() :: String.t()
  def query_param, do: @query_param

  @doc """
  The form. `tokens`, `suggestions`, and `rest_count` are those of
  `GobusgoWeb.FilterBar.options/1`, `query` the text of the text bar, and
  `supplied` whether the page's address supplies a filter.
  """
  attr :tokens, :list, required: true
  attr :suggestions, :list, required: true
  attr :rest_count, :integer, required: true
  attr :query, :string, required: true
  attr :supplied, :boolean, required: true

  def form(assigns) do
    assigns =
      assign(assigns,
        query_param: @query_param,
        query_debounce_ms: @query_debounce_ms,
        query_length_max: RouteOptions.query_length_max(),
        query_event: @query_event,
        add_event: @add_event,
        remove_event: @remove_event
      )

    ~H"""
    <form
      id="vehicle-filter"
      phx-hook="VehicleFilter"
      phx-change={@query_event}
      phx-submit={@query_event}
      data-supplied={to_string(@supplied)}
      class="text-sm"
    >
      <div id="vehicle-filter-bar" phx-hook="FilterBar">
        <div class="filter-bar">
          <label for="vehicle-filter-input" class="sr-only">Filter by agency or route</label>
          <ul
            id="vehicle-filter-tokens"
            aria-label="Applied filter"
            class="filter-tokens"
            hidden={@tokens == []}
          >
            <li
              :for={token <- @tokens}
              class="filter-token"
              data-field={token.field}
              data-value={token.id}
            >
              <span class="filter-kind">{field_label(token.field)}</span>
              <span class="filter-token-name">{token.name}</span>
              <button
                type="button"
                class="filter-token-remove"
                aria-label={"Remove #{String.downcase(field_label(token.field))} #{token.name}"}
                phx-click={@remove_event}
                phx-value-field={token.field}
                phx-value-id={token.id}
              >
                <span aria-hidden="true">×</span>
              </button>
            </li>
          </ul>
          <input
            id="vehicle-filter-input"
            type="text"
            name={@query_param}
            value={@query}
            role="combobox"
            aria-autocomplete="list"
            aria-controls="vehicle-filter-suggestions"
            aria-expanded={to_string(@suggestions != [])}
            placeholder={placeholder(@tokens)}
            maxlength={@query_length_max}
            autocomplete="off"
            spellcheck="false"
            phx-debounce={@query_debounce_ms}
            class="filter-bar-input"
          />
        </div>
        <ul
          id="vehicle-filter-suggestions"
          role="listbox"
          aria-label="Suggestions"
          class="filter-suggestions"
          hidden={@suggestions == []}
        >
          <li
            :for={{suggestion, index} <- Enum.with_index(@suggestions)}
            id={"vehicle-filter-suggestion-#{index}"}
            role="option"
            class="filter-suggestion"
            phx-click={@add_event}
            phx-value-field={suggestion.field}
            phx-value-id={suggestion.id}
          >
            <span class="filter-kind">{field_label(suggestion.field)}</span>
            <span class="font-medium">{suggestion.name}</span>
            <span :if={suggestion.detail != nil}>{suggestion.detail}</span>
            <span :if={suggestion.agency_name != nil} class="text-slate-600">
              {suggestion.agency_name}
            </span>
          </li>
        </ul>
        <p :if={@rest_count > 0} id="vehicle-filter-rest" class="mt-1 px-2 text-slate-600">
          {@rest_count} more; type more to narrow them
        </p>
      </div>
    </form>
    """
  end

  defp field_label(field), do: Map.fetch!(@field_labels, field)

  # A bar with tokens says what more text adds to them.
  defp placeholder([]), do: "Agency or route"
  defp placeholder([_token | _rest]), do: "Add an agency or route"
end
