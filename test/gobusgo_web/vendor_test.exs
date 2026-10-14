defmodule GobusgoWeb.VendorTest do
  # Sends requests for a vendored file through the endpoint with
  # Phoenix.ConnTest. The file is written here, in a directory of its own
  # under the application's vendored archives, and removed afterwards, so the
  # test needs no downloaded archive. The gzip copy beside it is written the
  # same way, as the vendor fetch writes one beside each compressible file.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @archive "test-archive-#{System.unique_integer([:positive])}"
  @font_directory "Noto Sans Regular"

  setup do
    directory =
      Application.app_dir(:gobusgo, Path.join(["priv/vendor", @archive, @font_directory]))

    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "0-255.pbf"), "glyphs")
    File.write!(Path.join(directory, "0-255.pbf.gz"), :zlib.gzip("glyphs"))

    on_exit(fn ->
      File.rm_rf!(Application.app_dir(:gobusgo, Path.join("priv/vendor", @archive)))
    end)

    :ok
  end

  describe "GET /vendor/<archive>/<path>" do
    test "answers 200 with a file whose directory name holds spaces" do
      conn = get(build_conn(), "/vendor/#{@archive}/Noto%20Sans%20Regular/0-255.pbf")

      assert response(conn, 200) == "glyphs"
    end

    test "lets a cache keep the file for an hour and gives it a validator" do
      conn = get(build_conn(), "/vendor/#{@archive}/Noto%20Sans%20Regular/0-255.pbf")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "answers 404 for a file the archive does not hold" do
      conn = get(build_conn(), "/vendor/#{@archive}/Noto%20Sans%20Regular/256-511.pbf")

      assert conn.status == 404
    end

    test "answers the gzip copy to a client that accepts gzip" do
      conn =
        build_conn()
        |> put_req_header("accept-encoding", "gzip")
        |> get("/vendor/#{@archive}/Noto%20Sans%20Regular/0-255.pbf")

      assert get_resp_header(conn, "content-encoding") == ["gzip"]
      assert conn |> response(200) |> :zlib.gunzip() == "glyphs"
    end

    test "answers the file as it is to a client that accepts no encoding" do
      conn = get(build_conn(), "/vendor/#{@archive}/Noto%20Sans%20Regular/0-255.pbf")

      assert get_resp_header(conn, "content-encoding") == []
      assert response(conn, 200) == "glyphs"
    end

    test "tells a cache that the answer depends on the accepted encodings" do
      conn = get(build_conn(), "/vendor/#{@archive}/Noto%20Sans%20Regular/0-255.pbf")

      assert get_resp_header(conn, "vary") == ["Accept-Encoding"]
    end
  end
end
