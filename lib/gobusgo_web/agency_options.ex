defmodule GobusgoWeb.AgencyOptions do
  @moduledoc """
  The options a page offers for a filter by agency: one per agency, checked
  when the filter selects it. Everything here is pure.

  The agencies come first, in name order and in identifier order within one
  name. A selected agency that is not among them comes after, in identifier
  order and named by its identifier, so a page can show and remove a
  selection it cannot name.
  """

  @type agency :: %{id: String.t(), name: String.t()}
  @type option :: %{id: String.t(), name: String.t(), checked: boolean()}

  @doc "Returns the options for `agencies` under a filter that selects `selected_ids`."
  @spec options(%{agencies: [agency()], selected_ids: [String.t()]}) :: [option()]
  def options(%{agencies: agencies, selected_ids: selected_ids})
      when is_list(agencies) and is_list(selected_ids) do
    held =
      for %{id: id, name: name} <- Enum.sort_by(agencies, &{&1.name, &1.id}) do
        %{id: id, name: name, checked: id in selected_ids}
      end

    held_ids = MapSet.new(agencies, & &1.id)

    unheld =
      for id <- Enum.sort(selected_ids), not MapSet.member?(held_ids, id) do
        %{id: id, name: id, checked: true}
      end

    held ++ unheld
  end
end
