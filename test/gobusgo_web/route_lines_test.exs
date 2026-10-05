defmodule GobusgoWeb.RouteLinesTest do
  # Verifies what the map page draws for routes as pure functions of the
  # fetches the two route views hold, written out here in the form the
  # records modules decode.
  use ExUnit.Case, async: true

  alias GobusgoWeb.RouteLines

  @earlier ~U[2026-10-05 01:00:00Z]
  @later ~U[2026-10-05 02:00:00Z]
  @agency_names %{"40" => "Sound Transit", "1" => "Metro Transit"}

  # A route of `agency_id` as the route view holds it, with no color and no
  # name unless `fields` supplies one.
  defp route(id, agency_id, fields \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "agencyId" => agency_id,
        "shortName" => nil,
        "longName" => nil,
        "description" => nil,
        "type" => 3,
        "color" => nil,
        "textColor" => nil,
        "url" => nil
      },
      fields
    )
  end

  defp route_fetch(agency_id, routes) do
    %{
      id: agency_id,
      route_ids: Enum.map(routes, & &1["id"]),
      routes: Map.new(routes, &{&1["id"], &1})
    }
  end

  defp path_fetch(route_id, points) do
    %{
      id: route_id,
      fetched_at: @earlier,
      polylines: for(text <- points, do: %{"points" => text, "pointCount" => 3, "levels" => nil})
    }
  end

  # The version of a route that has no color and no name.
  defp version(fields \\ %{}) do
    Map.merge(
      %{
        color: nil,
        short_name: nil,
        long_name: nil,
        agency_name: nil,
        path_fetch_microseconds: 1
      },
      fields
    )
  end

  # The version of the one route of agency "40", built from `fields` of its
  # record.
  defp version_of(fields, agency_names \\ @agency_names) do
    %{"40_1" => version} =
      RouteLines.versions(%{
        route_fetches: [route_fetch("40", [route("40_1", "40", fields)])],
        path_fetch_times: %{"40_1" => @earlier},
        agency_names: agency_names
      })

    version
  end

  describe "versions/1" do
    test "holds every route an agency lists that has a path, with its color and path time" do
      versions =
        RouteLines.versions(%{
          route_fetches: [
            route_fetch("40", [
              route("40_1", "40", %{"color" => "28813F"}),
              route("40_2", "40")
            ]),
            route_fetch("1", [route("1_1", "1", %{"color" => "FDB71A"})])
          ],
          path_fetch_times: %{"40_1" => @earlier, "40_2" => @later, "1_1" => @earlier},
          agency_names: %{}
        })

      assert versions == %{
               "40_1" =>
                 version(%{
                   color: "28813F",
                   path_fetch_microseconds: DateTime.to_unix(@earlier, :microsecond)
                 }),
               "40_2" =>
                 version(%{path_fetch_microseconds: DateTime.to_unix(@later, :microsecond)}),
               "1_1" =>
                 version(%{
                   color: "FDB71A",
                   path_fetch_microseconds: DateTime.to_unix(@earlier, :microsecond)
                 })
             }
    end

    test "holds the route's short name and long name" do
      version = version_of(%{"shortName" => "1 Line", "longName" => "Lynnwood - Federal Way"})

      assert %{short_name: "1 Line", long_name: "Lynnwood - Federal Way"} = version
    end

    test "holds no short name for a route that has none" do
      assert %{short_name: nil, long_name: "Lynnwood - Federal Way"} =
               version_of(%{"longName" => "Lynnwood - Federal Way"})
    end

    test "holds no long name for a route that has none" do
      assert %{short_name: "1 Line", long_name: nil} = version_of(%{"shortName" => "1 Line"})
    end

    test "holds the name of the agency the route's record names" do
      assert version_of(%{}).agency_name == "Sound Transit"
    end

    test "names the route's own agency for a route another agency lists" do
      %{"40_1" => version} =
        RouteLines.versions(%{
          route_fetches: [route_fetch("1", [route("40_1", "40")])],
          path_fetch_times: %{"40_1" => @earlier},
          agency_names: @agency_names
        })

      assert version.agency_name == "Sound Transit"
    end

    test "holds no agency name for a route whose agency has no name" do
      assert version_of(%{}, %{"1" => "Metro Transit"}).agency_name == nil
    end

    test "leaves out a route that has no path" do
      versions =
        RouteLines.versions(%{
          route_fetches: [route_fetch("40", [route("40_1", "40"), route("40_2", "40")])],
          path_fetch_times: %{"40_1" => @earlier},
          agency_names: @agency_names
        })

      assert Map.keys(versions) == ["40_1"]
    end

    test "leaves out a path whose route no agency lists" do
      versions =
        RouteLines.versions(%{
          route_fetches: [route_fetch("40", [route("40_1", "40")])],
          path_fetch_times: %{"40_1" => @earlier, "40_gone" => @earlier},
          agency_names: @agency_names
        })

      assert Map.keys(versions) == ["40_1"]
    end

    test "is empty before any fetch" do
      assert RouteLines.versions(%{route_fetches: [], path_fetch_times: %{}, agency_names: %{}}) ==
               %{}
    end
  end

  describe "changes/2" do
    @shown %{
      "40_1" => %{
        color: "28813F",
        short_name: "1 Line",
        long_name: "Lynnwood - Federal Way",
        agency_name: "Sound Transit",
        path_fetch_microseconds: 1
      },
      "40_2" => %{
        color: nil,
        short_name: nil,
        long_name: nil,
        agency_name: nil,
        path_fetch_microseconds: 1
      }
    }

    test "names nothing when the versions are the ones shown" do
      assert RouteLines.changes(@shown, @shown) == %{changed: [], removed: []}
    end

    test "names a route that is new, in identifier order" do
      versions = Map.merge(@shown, %{"40_3" => version(), "1_1" => version()})

      assert RouteLines.changes(@shown, versions) == %{changed: ["1_1", "40_3"], removed: []}
    end

    test "names a route that is gone as removed" do
      assert RouteLines.changes(@shown, Map.delete(@shown, "40_2")) ==
               %{changed: [], removed: ["40_2"]}
    end

    for {field, value} <- [
          path_fetch_microseconds: 2,
          color: "FFFFFF",
          short_name: "2 Line",
          long_name: "Lynnwood - Redmond",
          agency_name: "Sound Transit Express"
        ] do
      test "names a route of which only #{field} changed" do
        versions = put_in(@shown, ["40_1", unquote(field)], unquote(value))

        assert RouteLines.changes(@shown, versions) == %{changed: ["40_1"], removed: []}
      end
    end
  end

  describe "line/1" do
    test "holds the route, its color as a CSS color, its names, and its polylines in order" do
      assert RouteLines.line(%{
               version:
                 version(%{
                   color: "28813f",
                   short_name: "1 Line",
                   long_name: "Lynnwood - Federal Way",
                   agency_name: "Sound Transit"
                 }),
               path_fetch: path_fetch("40_1", ["mbpaHphuiVJVbhAn|F", "}xmaHxf}iVchAo|FKW"])
             }) == %{
               id: "40_1",
               color: "#28813f",
               short_name: "1 Line",
               long_name: "Lynnwood - Federal Way",
               agency_name: "Sound Transit",
               polylines: ["mbpaHphuiVJVbhAn|F", "}xmaHxf}iVchAo|FKW"]
             }
    end

    test "holds no name for a route that has none" do
      assert %{short_name: nil, long_name: nil, agency_name: nil} =
               RouteLines.line(%{version: version(), path_fetch: path_fetch("40_1", [])})
    end

    test "gives a route with no color the default color" do
      line =
        RouteLines.line(%{
          version: version(),
          path_fetch: path_fetch("40_1", ["mbpaHphuiVJVbhAn|F"])
        })

      assert line.color == RouteLines.default_color()
      assert line.color =~ ~r/\A#[0-9a-f]{6}\z/
    end

    test "holds no polylines for a route that has none" do
      assert %{id: "40_1", polylines: []} =
               RouteLines.line(%{version: version(), path_fetch: path_fetch("40_1", [])})
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
