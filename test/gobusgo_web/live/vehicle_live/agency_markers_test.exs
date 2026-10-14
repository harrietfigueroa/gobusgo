defmodule GobusgoWeb.VehicleLive.AgencyMarkersTest do
  # Checks which agencies' shown markers are out of date, by calling the
  # pure function with literal requests. The functions that read the views
  # are exercised through the page in `GobusgoWeb.VehicleLiveMarkersTest`.
  use ExUnit.Case, async: true

  alias GobusgoWeb.VehicleLive.AgencyMarkers

  for {name, shown_request_ids, request_ids, agency_ids} <- [
        {"an agency whose request is the one shown is up to date", %{"1" => "a"}, %{"1" => "a"},
         []},
        {"an agency whose request is another than the one shown is out of date", %{"1" => "a"},
         %{"1" => "b"}, ["1"]},
        {"an agency that is not shown is out of date", %{}, %{"40" => "a", "1" => "b"},
         ["1", "40"]},
        {"an agency shown that has no request comes after the changed ones",
         %{"1" => "a", "40" => "a"}, %{"40" => "b", "97" => "c"}, ["40", "97", "1"]}
      ] do
    test name do
      assert AgencyMarkers.changed_agency_ids(%{
               shown_request_ids: unquote(Macro.escape(shown_request_ids)),
               request_ids: unquote(Macro.escape(request_ids))
             }) == unquote(agency_ids)
    end
  end
end
