defmodule GobusgoWeb.VehicleLiveFavoriteStopTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap
  # directory the test names, hence the non-async case. The browser keeps the
  # favorite and writes the panel, so these tests observe the element the
  # panel's hook mounts on: where the page renders it, and that the page
  # leaves its content to the hook.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GobusgoWeb.VehicleLive.OpenStops

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @panel "#favorite-stop"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)
    :ok
  end

  defp write_manifest(tmp_dir),
    do: File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))

  defp panel(view) do
    view |> element(@panel) |> render() |> LazyHTML.from_fragment()
  end

  describe "GET /vehicles with a basemap" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
    end

    test "renders the favorite stops' panel empty, for its hook to fill" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      panel = panel(view)

      assert LazyHTML.attribute(panel, "phx-hook") == ["FavoriteStop"]
      assert panel |> LazyHTML.text() |> String.trim() == ""
    end

    test "leaves the panel's content to its hook across patches" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> panel() |> LazyHTML.attribute("phx-update") == ["ignore"]
    end

    test "renders the panel in the Favorites tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-favorites > #{@panel}")
    end

    test "hands the panel's hook the most favorites a rider keeps" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> panel() |> LazyHTML.attribute("data-favorite-count-max") ==
               [Integer.to_string(OpenStops.favorite_count_max())]
    end

    test "hands the stops' hook the most popups that open by themselves" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      [count] =
        view
        |> element("#stop-markers")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-auto-open-count-max")

      assert count == Integer.to_string(OpenStops.auto_open_count_max())
    end
  end

  describe "OpenStops.open_count_max/0" do
    test "is room for every favorite and every popup that opens by itself" do
      assert OpenStops.open_count_max() ==
               OpenStops.favorite_count_max() + OpenStops.auto_open_count_max()
    end

    test "keeps six favorites" do
      assert OpenStops.favorite_count_max() == 6
    end
  end

  describe "GET /vehicles without a basemap" do
    test "renders no favorite stop's panel" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel)
    end
  end
end
