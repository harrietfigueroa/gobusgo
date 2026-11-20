defmodule GobusgoWeb.WalkGraphFilesTest do
  # Sends requests for a walk graph file the local file writer stored under
  # `intersections/` through the endpoint with Phoenix.ConnTest. The test
  # names its temporary directory's intersections directory as the one
  # served, so the module runs apart from the others.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @content "the content of a walk graph shard"
  @destination "intersections/walk-graph-0123456789abcdef-4761_-8156.bin.gz"
  @manifest "intersections/walking-manifest-20261110T220000Z-aa.json"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :intersections)
    Application.put_env(:gobusgo, :intersections, dir: Path.join(tmp_dir, "intersections"))
    on_exit(fn -> Application.put_env(:gobusgo, :intersections, configured) end)

    for destination <- [@destination, @manifest] do
      :ok =
        Gobusgo.Writer.write(
          %{destination: destination, content: @content, reader_keep_seconds: 31_536_000},
          base_dir: tmp_dir
        )
    end

    :ok
  end

  test "answers the file as the gzip stream of its content, cached for a year as immutable" do
    conn = get(build_conn(), "/" <> @destination)

    assert :zlib.gunzip(response(conn, 200)) == @content
    assert get_resp_header(conn, "content-type") == ["application/gzip"]
    assert get_resp_header(conn, "content-encoding") == []
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "answers 404 for a file that is not stored" do
    conn = get(build_conn(), "/intersections/walk-graph-absent.bin.gz")
    assert conn.status == 404
  end

  test "does not serve the manifest from the file directory" do
    conn = get(build_conn(), "/" <> @manifest)
    assert conn.status == 404
  end
end
