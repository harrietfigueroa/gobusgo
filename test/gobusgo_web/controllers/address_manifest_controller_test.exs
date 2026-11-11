defmodule GobusgoWeb.AddressManifestControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest and reads the
  # manifest of the application's addresses process, which holds none under
  # test until a test records one and holds none again when the test ends.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.Addresses

  @endpoint GobusgoWeb.Endpoint

  @manifest %{
    "builtAt" => "2026-11-10T12:00:00Z",
    "inputsSha256" => String.duplicate("ab", 32),
    "index" => %{
      "path" => "/addresses/dt=2026-11-10/index.bin.gz",
      "byteSize" => 10,
      "sha256" => String.duplicate("cd", 32)
    },
    "shards" => []
  }

  defp record_manifest do
    :ok =
      Addresses.record(Addresses, %{
        county: :king,
        manifest: @manifest,
        inputs_sha256: :binary.copy(<<0xAB>>, 32),
        built_at: ~U[2026-11-10 12:00:00Z]
      })

    on_exit(fn ->
      :sys.replace_state(Addresses, fn state -> %{state | counties: %{}} end)
    end)
  end

  test "answers 503 problem details with Retry-After while there is no build" do
    conn = get(build_conn(), "/api/addresses/manifest")

    assert json_response(conn, 503)["status"] == 503
    assert get_resp_header(conn, "retry-after") == ["60"]
    assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
  end

  test "answers every county's manifest as JSON that every request revalidates" do
    record_manifest()
    conn = get(build_conn(), "/api/addresses/manifest")

    assert json_response(conn, 200) == %{"counties" => [Map.put(@manifest, "county", "king")]}
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert [~s(") <> _tag] = get_resp_header(conn, "etag")
  end

  test "the tag is the SHA-256 of the body" do
    record_manifest()
    conn = get(build_conn(), "/api/addresses/manifest")

    expected =
      ~s(") <> Base.encode16(:crypto.hash(:sha256, conn.resp_body), case: :lower) <> ~s(")

    assert get_resp_header(conn, "etag") == [expected]
  end

  test "answers 304 with no body to a request that names the current tag" do
    record_manifest()
    [etag] = build_conn() |> get("/api/addresses/manifest") |> get_resp_header("etag")

    conn = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/addresses/manifest")

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "answers 200 to a request that names another tag" do
    record_manifest()

    conn =
      build_conn()
      |> put_req_header("if-none-match", ~s("other"))
      |> get("/api/addresses/manifest")

    assert conn.status == 200
  end
end
