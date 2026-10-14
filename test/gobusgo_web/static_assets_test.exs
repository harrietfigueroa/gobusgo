defmodule GobusgoWeb.StaticAssetsTest do
  # Sends requests for a built asset through the endpoint with
  # Phoenix.ConnTest and checks that the gzip copy the digest writes is served
  # to a client that accepts it. The asset and its copy are written here, in a
  # directory of their own under the built assets, and removed afterwards, so
  # the test needs no asset build. The digest's own choice of which files get
  # a copy is checked through its compressor.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @directory "test-assets-#{System.unique_integer([:positive])}"
  @content "export const library = true\n"
  @asset_path "/assets/#{@directory}/library.mjs"

  setup do
    directory = Application.app_dir(:gobusgo, Path.join(["priv/static/assets", @directory]))
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "library.mjs"), @content)
    File.write!(Path.join(directory, "library.mjs.gz"), :zlib.gzip(@content))
    on_exit(fn -> File.rm_rf!(directory) end)
    :ok
  end

  describe "GET /assets/<path>" do
    test "answers the gzip copy to a client that accepts gzip" do
      conn = build_conn() |> put_req_header("accept-encoding", "gzip") |> get(@asset_path)

      assert get_resp_header(conn, "content-encoding") == ["gzip"]
      assert conn |> response(200) |> :zlib.gunzip() == @content
    end

    test "answers the file as it is to a client that accepts no encoding" do
      conn = get(build_conn(), @asset_path)

      assert get_resp_header(conn, "content-encoding") == []
      assert response(conn, 200) == @content
    end

    test "tells a cache that the answer depends on the accepted encodings" do
      conn = get(build_conn(), @asset_path)

      assert get_resp_header(conn, "vary") == ["Accept-Encoding"]
    end
  end

  describe "the digest of the built assets" do
    # MapLibre's three files are ES modules, which the digest compresses only
    # when the configuration names their extension.
    for file <- ~w(app.js app.css maplibre-gl.mjs) do
      test "writes a gzip copy of #{file}" do
        assert {:ok, _compressed} = Phoenix.Digester.Gzip.compress_file(unquote(file), @content)
      end
    end
  end
end
