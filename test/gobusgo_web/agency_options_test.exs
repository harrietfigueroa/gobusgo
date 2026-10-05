defmodule GobusgoWeb.AgencyOptionsTest do
  # Verifies the options of an agency filter as a pure function: each case
  # names the agencies a view holds and the agencies a filter selects, and
  # the options a page must offer.
  use ExUnit.Case, async: true

  alias GobusgoWeb.AgencyOptions

  @agencies [%{id: "40", name: "Sound Transit"}, %{id: "1", name: "Metro Transit"}]

  test "offers every agency in name order, unchecked without a selection" do
    assert AgencyOptions.options(%{agencies: @agencies, selected_ids: []}) == [
             %{id: "1", name: "Metro Transit", checked: false},
             %{id: "40", name: "Sound Transit", checked: false}
           ]
  end

  test "checks the selected agencies" do
    assert AgencyOptions.options(%{agencies: @agencies, selected_ids: ["40"]}) == [
             %{id: "1", name: "Metro Transit", checked: false},
             %{id: "40", name: "Sound Transit", checked: true}
           ]
  end

  test "orders agencies of one name by identifier" do
    agencies = [%{id: "b", name: "Transit"}, %{id: "a", name: "Transit"}]

    assert [%{id: "a"}, %{id: "b"}] =
             AgencyOptions.options(%{agencies: agencies, selected_ids: []})
  end

  test "offers a selected agency that is not held, checked and named by its identifier, last" do
    assert AgencyOptions.options(%{agencies: @agencies, selected_ids: ["zz", "97"]}) == [
             %{id: "1", name: "Metro Transit", checked: false},
             %{id: "40", name: "Sound Transit", checked: false},
             %{id: "97", name: "97", checked: true},
             %{id: "zz", name: "zz", checked: true}
           ]
  end

  test "offers nothing for no agency and no selection" do
    assert AgencyOptions.options(%{agencies: [], selected_ids: []}) == []
  end
end
