defmodule GobusgoWeb.VehicleLive.MapDescription do
  @moduledoc """
  The sentence of the vehicle map's description that says what the filter
  keeps, read by a screen reader with the map's canvas. It names the
  agencies and the routes as the summary line does, by the names of the
  filter bar's tokens, a trip's routes in the order the journey rides them,
  and nothing for a refused filter.

  It is pure: the filter, the tokens, and the trip reach it as arguments.
  """

  alias GobusgoWeb.VehicleLive.Filter

  @shown "It shows the vehicles, route lines, and stops of"

  @doc """
  The sentence for the page's `filter`, the filter bar's `tokens` that name
  its values, and the open `trip`, or `nil` while none is open.
  """
  @spec filter_sentence(%{filter: Filter.t(), tokens: [map()], trip: map() | nil}) :: String.t()
  def filter_sentence(%{filter: :refused}),
    do: "It shows nothing, because the filter in the address is not valid."

  def filter_sentence(%{tokens: tokens, trip: %{route_ids: [_ | _] = route_ids}}) do
    names = Map.new(for %{field: "route", id: id, name: name} <- tokens, do: {id, name})
    route_names = for id <- route_ids, do: Map.get(names, id, id)
    "#{@shown} the trip's #{plural("route", route_names)}: #{listed(route_names)}."
  end

  def filter_sentence(%{tokens: tokens}) do
    agency_names = for %{field: "agency", name: name} <- tokens, do: name
    route_names = for %{field: "route", name: name} <- tokens, do: name
    "#{@shown} #{kept(agency_names, route_names)}."
  end

  defp kept([], []), do: "every agency"
  defp kept(agency_names, []), do: listed(agency_names)
  defp kept([], route_names), do: routes(route_names)
  defp kept(agency_names, route_names), do: "#{routes(route_names)} of #{listed(agency_names)}"

  defp routes(route_names), do: "the #{plural("route", route_names)} #{listed(route_names)}"

  defp plural(word, [_one]), do: word
  defp plural(word, [_ | _]), do: word <> "s"

  # A list of names in prose: one alone, two joined by "and", and three or
  # more with commas and a last "and".
  defp listed([name]), do: name
  defp listed([first, second]), do: "#{first} and #{second}"

  defp listed([_, _, _ | _] = names) do
    {leading, [last]} = Enum.split(names, -1)
    "#{Enum.join(leading, ", ")}, and #{last}"
  end
end
