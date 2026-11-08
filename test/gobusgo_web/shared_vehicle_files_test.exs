defmodule GobusgoWeb.SharedVehicleFilesTest do
  # Sends requests for the files of one published shared vehicle fetch
  # through the endpoint with Phoenix.ConnTest. The files are written by
  # the local file writer into the test's temporary directory, as a build
  # writes them, and the test names that directory's shared vehicle
  # directory as the one served, so the module runs apart from the others.
  # A file's address is its destination, which a page reads from the index.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.Gbfs.VehicleTileSet

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint

  defp publish(tmp_dir) do
    vehicle = %{
      id: "bike-1",
      position: %{lat: 47.6114, lon: -122.337},
      vehicle_type_id: nil,
      current_range_meters: 12_000,
      is_disabled: false,
      is_reserved: false,
      last_reported: nil
    }

    set =
      VehicleTileSet.build(%{
        fetched: %{
          kind: :fetched,
          id: "lime_seattle",
          version: "2.2",
          last_updated: ~U[2026-11-08 19:08:00Z],
          ttl: 60,
          vehicles: [vehicle],
          data_sha256: String.duplicate("0", 64),
          destination: "raw/gbfs/free-bike-status/test",
          fetched_at: ~U[2026-11-08 19:08:30Z],
          request_id: Gobusgo.RequestId.generate()
        },
        type_fetches: []
      })

    for file <- [set.index | set.files], do: :ok = Gobusgo.Writer.write(file, base_dir: tmp_dir)
    set
  end

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :shared_vehicle_tiles)
    served_dir = Path.join(tmp_dir, VehicleTileSet.prefix())
    Application.put_env(:gobusgo, :shared_vehicle_tiles, dir: served_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :shared_vehicle_tiles, configured) end)
    %{set: publish(tmp_dir)}
  end

  describe "GET /shared-vehicles/<file>" do
    test "answers each file as the gzip stream of its content", %{set: set} do
      for file <- [set.index | set.files] do
        conn = get(build_conn(), "/" <> file.destination)

        assert :zlib.gunzip(response(conn, 200)) == file.content
      end
    end

    test "names the stream's type and no content encoding", %{set: set} do
      conn = get(build_conn(), "/" <> set.index.destination)

      assert {get_resp_header(conn, "content-type"), get_resp_header(conn, "content-encoding")} ==
               {["application/gzip"], []}
    end

    test "lets a cache keep a file for a minute without revalidating it", %{set: set} do
      conn = get(build_conn(), "/" <> set.index.destination)

      assert get_resp_header(conn, "cache-control") == ["public, max-age=60, immutable"]
    end

    test "answers 404 for a file that is not stored" do
      conn = get(build_conn(), "/shared-vehicles/dt=2026-11-08/absent.bin.gz")

      assert conn.status == 404
    end
  end
end
