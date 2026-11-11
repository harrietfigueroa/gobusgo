defmodule GobusgoWeb.PlacesFilesTest do
  # Sends requests for a published places file and its manifest through the
  # endpoint with Phoenix.ConnTest. The files are published by the local file
  # writer into the test's temporary directory, and the test names that
  # directory's places directory as the one served, so the module runs apart
  # from the others.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.Deleter
  alias Gobusgo.Places.License
  alias Gobusgo.Places.Publication
  alias Gobusgo.Test.PlaceFixture
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :places)
    Application.put_env(:gobusgo, :places, dir: Path.join(tmp_dir, Publication.directory()))
    on_exit(fn -> Application.put_env(:gobusgo, :places, configured) end)

    request = %{
      source_date: PlaceFixture.source_date(),
      places: PlaceFixture.places(),
      built_at: ~U[2026-11-10 22:00:00Z]
    }

    options = [
      write_options: [backend: Writer.LocalFile, base_dir: tmp_dir],
      delete_options: [backend: Deleter.LocalFile, base_dir: tmp_dir]
    ]

    {:ok, published} = Publication.publish(request, options)
    %{published: published}
  end

  describe "GET /places/<file>" do
    test "answers the file as the gzip stream of its content", %{published: published} do
      conn = get(build_conn(), "/" <> published.file_destination)

      assert :zlib.gunzip(response(conn, 200)) == PlaceFixture.encode()
    end

    test "names the stream's type and no content encoding", %{published: published} do
      conn = get(build_conn(), "/" <> published.file_destination)

      assert {get_resp_header(conn, "content-type"), get_resp_header(conn, "content-encoding")} ==
               {["application/gzip"], []}
    end

    test "lets a cache keep the file for a year as immutable", %{published: published} do
      conn = get(build_conn(), "/" <> published.file_destination)

      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "answers 404 for a file that is not stored" do
      conn = get(build_conn(), "/places/places-#{String.duplicate("0", 64)}.bin.gz")

      assert conn.status == 404
    end
  end

  describe "GET /places/NOTICE.txt" do
    test "answers the notice's text" do
      conn = get(build_conn(), "/places/NOTICE.txt")

      assert response(conn, 200) == License.notice_text()
    end

    test "names its type as UTF-8 text" do
      conn = get(build_conn(), "/places/NOTICE.txt")

      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end

    test "must be revalidated and carries an etag" do
      conn = get(build_conn(), "/places/NOTICE.txt")

      assert {get_resp_header(conn, "cache-control"), get_resp_header(conn, "etag") != []} ==
               {["no-cache"], true}
    end
  end

  describe "GET /places/manifest.json" do
    test "names the current file", %{published: published} do
      conn = get(build_conn(), "/places/manifest.json")

      assert %{"file" => %{"path" => path}} = conn |> response(200) |> JSON.decode!()
      assert path == published.file_destination
    end

    test "must be revalidated and carries an etag" do
      conn = get(build_conn(), "/places/manifest.json")

      assert {get_resp_header(conn, "cache-control"), get_resp_header(conn, "etag") != []} ==
               {["no-cache"], true}
    end
  end
end
