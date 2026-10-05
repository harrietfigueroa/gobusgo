defmodule GobusgoWeb.RouteLinesTest do
  # Verifies what the map page draws for routes as pure functions of the
  # fetches the two route views hold, written out here in the form the
  # records modules decode.
  use ExUnit.Case, async: true

  alias GobusgoWeb.RouteLines

  @earlier ~U[2026-10-05 01:00:00Z]
  @later ~U[2026-10-05 02:00:00Z]

  defp route_fetch(agency_id, routes) do
    %{
      id: agency_id,
      route_ids: Enum.map(routes, fn {id, _color} -> id end),
      routes: Map.new(routes, fn {id, color} -> {id, %{"id" => id, "color" => color}} end)
    }
  end

  defp path_fetch(route_id, points) do
    %{
      id: route_id,
      fetched_at: @earlier,
      polylines: for(text <- points, do: %{"points" => text, "pointCount" => 3, "levels" => nil})
    }
  end

  describe "versions/1" do
    test "holds every route an agency lists that has a path, with its color and path time" do
      versions =
        RouteLines.versions(%{
          route_fetches: [
            route_fetch("40", [{"40_1", "28813F"}, {"40_2", nil}]),
            route_fetch("1", [{"1_1", "FDB71A"}])
          ],
          path_fetch_times: %{"40_1" => @earlier, "40_2" => @later, "1_1" => @earlier}
        })

      assert versions == %{
               "40_1" => {"28813F", DateTime.to_unix(@earlier, :microsecond)},
               "40_2" => {nil, DateTime.to_unix(@later, :microsecond)},
               "1_1" => {"FDB71A", DateTime.to_unix(@earlier, :microsecond)}
             }
    end

    test "leaves out a route that has no path" do
      versions =
        RouteLines.versions(%{
          route_fetches: [route_fetch("40", [{"40_1", "28813F"}, {"40_2", "28813F"}])],
          path_fetch_times: %{"40_1" => @earlier}
        })

      assert Map.keys(versions) == ["40_1"]
    end

    test "leaves out a path whose route no agency lists" do
      versions =
        RouteLines.versions(%{
          route_fetches: [route_fetch("40", [{"40_1", "28813F"}])],
          path_fetch_times: %{"40_1" => @earlier, "40_gone" => @earlier}
        })

      assert Map.keys(versions) == ["40_1"]
    end

    test "is empty before any fetch" do
      assert RouteLines.versions(%{route_fetches: [], path_fetch_times: %{}}) == %{}
    end
  end

  describe "changes/2" do
    @shown %{"40_1" => {"28813F", 1}, "40_2" => {nil, 1}}

    test "names nothing when the versions are the ones shown" do
      assert RouteLines.changes(@shown, @shown) == %{changed: [], removed: []}
    end

    test "names a route that is new, in identifier order" do
      versions = Map.merge(@shown, %{"40_3" => {nil, 1}, "1_1" => {nil, 1}})

      assert RouteLines.changes(@shown, versions) == %{changed: ["1_1", "40_3"], removed: []}
    end

    test "names a route whose path is newer" do
      versions = %{@shown | "40_1" => {"28813F", 2}}

      assert RouteLines.changes(@shown, versions) == %{changed: ["40_1"], removed: []}
    end

    test "names a route whose color changed" do
      versions = %{@shown | "40_2" => {"FFFFFF", 1}}

      assert RouteLines.changes(@shown, versions) == %{changed: ["40_2"], removed: []}
    end

    test "names a route that is gone as removed" do
      assert RouteLines.changes(@shown, Map.delete(@shown, "40_2")) ==
               %{changed: [], removed: ["40_2"]}
    end
  end

  describe "line/1" do
    test "holds the route, its color as a CSS color, and its encoded polylines in order" do
      assert RouteLines.line(%{
               color: "28813f",
               path_fetch: path_fetch("40_1", ["mbpaHphuiVJVbhAn|F", "}xmaHxf}iVchAo|FKW"])
             }) == %{
               id: "40_1",
               color: "#28813f",
               polylines: ["mbpaHphuiVJVbhAn|F", "}xmaHxf}iVchAo|FKW"]
             }
    end

    test "gives a route with no color the default color" do
      line =
        RouteLines.line(%{color: nil, path_fetch: path_fetch("40_1", ["mbpaHphuiVJVbhAn|F"])})

      assert line.color == RouteLines.default_color()
      assert line.color =~ ~r/\A#[0-9a-f]{6}\z/
    end

    test "holds no polylines for a route that has none" do
      assert %{id: "40_1", polylines: []} =
               RouteLines.line(%{color: nil, path_fetch: path_fetch("40_1", [])})
    end
  end

  describe "chunks/1" do
    test "splits the lines into events of at most the line count each" do
      lines = for index <- 1..(RouteLines.event_line_count_max() * 2 + 1), do: %{id: "r#{index}"}

      assert lines |> RouteLines.chunks() |> Enum.map(&length/1) ==
               [RouteLines.event_line_count_max(), RouteLines.event_line_count_max(), 1]
    end

    test "is no event for no lines" do
      assert RouteLines.chunks([]) == []
    end
  end
end
