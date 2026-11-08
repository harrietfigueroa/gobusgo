defmodule GobusgoWeb.TilesTest do
  # Sends requests for a locally stored tile archive through the endpoint
  # with Phoenix.ConnTest and checks what a PMTiles reader depends on: whole
  # and partial content and the caching header. The archive is literal bytes
  # in the test's temporary directory, which the test names as the tile
  # directory, so the module runs apart from the others.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @archive_path "route-stops/dt=2026-10-14/route-stops-20261014T153000000000Z.pmtiles"
  @archive for byte <- 0..99, into: <<>>, do: <<byte>>

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :tiles)
    Application.put_env(:gobusgo, :tiles, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :tiles, configured) end)

    path = Path.join(tmp_dir, @archive_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @archive)
    :ok
  end

  describe "GET /tiles/<archive>" do
    test "answers 200 with the whole archive" do
      conn = get(build_conn(), "/tiles/" <> @archive_path)

      assert response(conn, 200) == @archive
    end

    test "answers 206 with the bytes of a range" do
      conn =
        build_conn() |> put_req_header("range", "bytes=0-15") |> get("/tiles/" <> @archive_path)

      assert response(conn, 206) == binary_part(@archive, 0, 16)
    end

    test "lets a cache keep the archive for a year without revalidating it" do
      conn = get(build_conn(), "/tiles/" <> @archive_path)

      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "answers 404 for an archive that is not stored" do
      conn = get(build_conn(), "/tiles/route-stops/dt=2026-10-14/absent.pmtiles")

      assert conn.status == 404
    end

    test "lets no cache keep the 404 for an archive that is not stored for a year" do
      conn = get(build_conn(), "/tiles/route-stops/dt=2026-10-14/absent.pmtiles")

      refute "public, max-age=31536000, immutable" in get_resp_header(conn, "cache-control")
    end
  end
end
