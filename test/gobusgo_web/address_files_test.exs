defmodule GobusgoWeb.AddressFilesTest do
  # Sends requests for a file the local file writer stored under
  # `addresses/` through the endpoint with Phoenix.ConnTest. The test names
  # its temporary directory's address directory as the one served, so the
  # module runs apart from the others.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @content "the content of a shard"
  @destination "addresses/dt=2026-11-10/shard-0123.bin.gz"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :addresses)
    Application.put_env(:gobusgo, :addresses, dir: Path.join(tmp_dir, "addresses"))
    on_exit(fn -> Application.put_env(:gobusgo, :addresses, configured) end)

    :ok =
      Gobusgo.Writer.write(
        %{destination: @destination, content: @content, reader_keep_seconds: 31_536_000},
        base_dir: tmp_dir
      )
  end

  test "answers the file as the gzip stream of its content" do
    conn = get(build_conn(), "/" <> @destination)
    assert :zlib.gunzip(response(conn, 200)) == @content
  end

  test "names the stream's type and no content encoding" do
    conn = get(build_conn(), "/" <> @destination)

    assert {get_resp_header(conn, "content-type"), get_resp_header(conn, "content-encoding")} ==
             {["application/gzip"], []}
  end

  test "lets a cache keep the file for a year as immutable" do
    conn = get(build_conn(), "/" <> @destination)
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "answers 404 for a file that is not stored" do
    conn = get(build_conn(), "/addresses/dt=2026-11-10/absent.bin.gz")
    assert conn.status == 404
  end
end
