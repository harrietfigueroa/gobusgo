defmodule GobusgoWeb.VehicleLive.LinesTest do
  # Checks whether two sets of line versions hold the same routes, by
  # calling the pure function with literal versions. The functions that read
  # the route views are exercised through the page in
  # `GobusgoWeb.VehicleLiveRouteLinesTest`.
  use ExUnit.Case, async: true

  alias GobusgoWeb.VehicleLive.Lines

  for {name, shown, versions, same} <- [
        {"the same routes at other versions are the same routes", %{"1_100" => :a},
         %{"1_100" => :b}, true},
        {"no routes on both sides are the same routes", %{}, %{}, true},
        {"a route that appears is another set of routes", %{"1_100" => :a},
         %{"1_100" => :a, "1_200" => :a}, false},
        {"a route that goes is another set of routes", %{"1_100" => :a, "1_200" => :a},
         %{"1_100" => :a}, false},
        {"one route replaced by another is another set of routes", %{"1_100" => :a},
         %{"1_200" => :a}, false}
      ] do
    test name do
      assert Lines.same_routes?(%{
               shown: unquote(Macro.escape(shown)),
               versions: unquote(Macro.escape(versions))
             }) == unquote(same)
    end
  end
end
