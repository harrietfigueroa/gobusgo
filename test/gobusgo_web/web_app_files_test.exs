defmodule GobusgoWeb.WebAppFilesTest do
  # Sends requests for the web app manifest, its icons, and the service
  # worker through the endpoint with Phoenix.ConnTest. The manifest and the
  # icons are checked in; the service worker is built, so a stand-in is
  # written where the build writes it when no build has, and removed
  # afterwards. The stand-in is a file of the application's own directory,
  # global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @stand_in "self.addEventListener(\"fetch\", () => {})\n"

  setup do
    path = Application.app_dir(:gobusgo, "priv/static/sw.js")

    if File.exists?(path) do
      :ok
    else
      File.write!(path, @stand_in)
      on_exit(fn -> File.rm!(path) end)
    end
  end

  defp manifest do
    build_conn() |> get("/manifest.webmanifest") |> response(200) |> JSON.decode!()
  end

  describe "GET /manifest.webmanifest" do
    test "answers as a web app manifest" do
      conn = get(build_conn(), "/manifest.webmanifest")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/manifest+json"
    end

    test "opens the vehicle page in a window of its own, with the whole site in scope" do
      assert %{"start_url" => "/vehicles", "scope" => "/", "display" => "standalone"} = manifest()
    end

    test "names the application" do
      assert %{"name" => "Gobusgo", "short_name" => "Gobusgo"} = manifest()
    end

    test "names a theme and a background color" do
      assert %{"theme_color" => "#" <> _theme, "background_color" => "#" <> _background} =
               manifest()
    end

    test "launches on the dark theme's page color" do
      %{"dark" => dark} = "assets/js/theme_colors.json" |> File.read!() |> JSON.decode!()

      assert manifest()["background_color"] == dark
    end

    for size <- ["192x192", "512x512"] do
      test "names an icon of #{size}" do
        icons = manifest()["icons"]

        assert Enum.any?(icons, &(&1["sizes"] == unquote(size) and &1["purpose"] == "any"))
      end
    end

    test "names a maskable icon" do
      assert Enum.any?(manifest()["icons"], &(&1["purpose"] == "maskable"))
    end

    test "names icons the endpoint serves as PNG images" do
      for %{"src" => src} <- manifest()["icons"] do
        conn = get(build_conn(), src)

        assert conn.status == 200, src
        assert get_resp_header(conn, "content-type") == ["image/png"], src
      end
    end
  end

  describe "GET /icons/apple-touch-icon.png" do
    test "answers a PNG image" do
      conn = get(build_conn(), "/icons/apple-touch-icon.png")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end
  end

  describe "GET /sw.js" do
    test "answers the service worker as JavaScript" do
      conn = get(build_conn(), "/sw.js")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "javascript"
    end

    test "has a cache revalidate the service worker on every use" do
      conn = get(build_conn(), "/sw.js")

      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end
end
