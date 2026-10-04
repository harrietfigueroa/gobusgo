defmodule GobusgoWeb.BasemapTest do
  # Sends requests for basemap files through the endpoint with
  # Phoenix.ConnTest and checks what a PMTiles reader depends on: whole and
  # partial content, the validator, and the caching headers. The files are
  # literal bytes in the test's temporary directory, which the test names as
  # the basemap directory, so the module runs apart from the others.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @archive_name "basemap-20261004-01.pmtiles"
  @archive_path "/basemap/#{@archive_name}"
  @archive_byte_count 100
  @archive for byte <- 0..(@archive_byte_count - 1), into: <<>>, do: <<byte>>
  @manifest ~s({"archives":[]})

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)

    File.write!(Path.join(tmp_dir, @archive_name), @archive)
    File.write!(Path.join(tmp_dir, "manifest.json"), @manifest)
    File.write!(Path.join(tmp_dir, "notes.txt"), "not a basemap file")
    :ok
  end

  defp get_range(range) do
    build_conn() |> put_req_header("range", range) |> get(@archive_path)
  end

  describe "GET /basemap/<archive>" do
    test "answers 200 with the whole archive and says it accepts ranges" do
      conn = get(build_conn(), @archive_path)

      assert response(conn, 200) == @archive
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "lets a cache keep the archive for an hour and gives it a validator" do
      conn = get(build_conn(), @archive_path)

      assert get_resp_header(conn, "cache-control") == ["public, max-age=3600"]
      assert [_etag] = get_resp_header(conn, "etag")
    end

    for {description, range, content_range, offset, byte_count} <- [
          {"a range inside the archive", "bytes=10-19", "bytes 10-19/100", 10, 10},
          {"the first byte", "bytes=0-0", "bytes 0-0/100", 0, 1},
          {"a range to the end", "bytes=90-", "bytes 90-99/100", 90, 10},
          {"the last bytes", "bytes=-5", "bytes 95-99/100", 95, 5},
          {"a range that ends past the archive", "bytes=95-200", "bytes 95-99/100", 95, 5}
        ] do
      test "answers 206 with the bytes of #{description}" do
        conn = get_range(unquote(range))

        assert response(conn, 206) == binary_part(@archive, unquote(offset), unquote(byte_count))
        assert get_resp_header(conn, "content-range") == [unquote(content_range)]
      end
    end

    test "answers 416 with the archive's size for a range that starts past its end" do
      conn = get_range("bytes=100-200")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */100"]
    end

    test "answers 304 for the validator it gave" do
      [etag] = build_conn() |> get(@archive_path) |> get_resp_header("etag")

      conn = build_conn() |> put_req_header("if-none-match", etag) |> get(@archive_path)

      assert response(conn, 304) == ""
    end

    test "answers a HEAD request with the headers and no body" do
      conn = head(build_conn(), @archive_path)

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "answers 404 for an archive that does not exist" do
      conn = get(build_conn(), "/basemap/basemap-20260101-01.pmtiles")

      assert conn.status == 404
    end
  end

  describe "GET /basemap/manifest.json" do
    test "answers 200 with the manifest as JSON, revalidated on every use" do
      conn = get(build_conn(), "/basemap/manifest.json")

      assert response(conn, 200) == @manifest
      assert get_resp_header(conn, "content-type") == ["application/json"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end
  end

  describe "another file in the basemap directory" do
    test "is not served" do
      conn = get(build_conn(), "/basemap/notes.txt")

      assert conn.status == 404
    end
  end
end
