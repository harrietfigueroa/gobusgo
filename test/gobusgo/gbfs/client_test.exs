defmodule Gobusgo.Gbfs.ClientTest do
  # Drives fetch/3 against Lime Seattle's recorded files, served from a
  # Req.Test stub by address: a route the case leaves out answers 404, as an
  # absent version or file does on the live feed. Each case observes what
  # fetch/3 returns, and the request cases also what reached the stub.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Gbfs.Client

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)
  @stub_name Client
  @deadline_ms 2_000

  @origin "https://data.lime.bike/api/partners"
  @discovery_urls %{
    "3.0" => @origin <> "/v3/gbfs/seattle/gbfs.json",
    "2.2" => @origin <> "/v2/gbfs/seattle/gbfs.json",
    "1.0" => @origin <> "/v1/gbfs/seattle/gbfs.json"
  }
  @system %{discovery_urls: @discovery_urls, language: "en"}

  @v3_vehicle_status @origin <> "/v3/gbfs/seattle/vehicle_status.json"
  @v3_vehicle_types @origin <> "/v3/gbfs/seattle/vehicle_types.json"
  @v2_free_bike_status @origin <> "/v2/gbfs/seattle/free_bike_status"
  @v2_vehicle_types @origin <> "/v2/gbfs/seattle/vehicle_types"
  @v1_free_bike_status @origin <> "/v1/gbfs/seattle/free_bike_status"

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp routes("3.0") do
    %{
      @discovery_urls["3.0"] => {:fixture, "lime_v3_gbfs"},
      @v3_vehicle_status => {:fixture, "lime_v3_vehicle_status"},
      @v3_vehicle_types => {:fixture, "lime_v3_vehicle_types"}
    }
  end

  defp routes("2.2") do
    %{
      @discovery_urls["2.2"] => {:fixture, "lime_v2_gbfs"},
      @v2_free_bike_status => {:fixture, "lime_v2_free_bike_status"},
      @v2_vehicle_types => {:fixture, "lime_v2_vehicle_types"}
    }
  end

  defp routes("1.0") do
    %{
      @discovery_urls["1.0"] => {:fixture, "lime_v1_gbfs"},
      @v1_free_bike_status => {:fixture, "lime_v1_free_bike_status"}
    }
  end

  defp routes(versions) when is_list(versions) do
    Enum.reduce(versions, %{}, &Map.merge(&2, routes(&1)))
  end

  # Serves each route's response and reports every request to the test.
  defp serve(routes) do
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      url = "https://" <> conn.host <> conn.request_path
      send(test_pid, {:requested, url, conn.req_headers, conn.query_string})

      case Map.fetch(routes, url) do
        {:ok, response} -> respond(conn, response)
        :error -> Plug.Conn.send_resp(conn, 404, "<html>404 Not Found</html>")
      end
    end)
  end

  defp respond(conn, {:fixture, name}), do: respond(conn, {:body, 200, fixture(name)})

  defp respond(conn, {:body, status, body}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond(conn, {:gzip, body}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("content-encoding", "gzip")
    |> Plug.Conn.send_resp(200, :zlib.gzip(body))
  end

  defp respond(conn, {:encoded, encoding, body}) do
    conn
    |> Plug.Conn.put_resp_header("content-encoding", encoding)
    |> Plug.Conn.send_resp(200, body)
  end

  defp respond(conn, {:redirect, location}) do
    conn
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(302, "")
  end

  defp respond(conn, {:sleep, sleep_ms}) do
    Process.sleep(sleep_ms)
    Plug.Conn.send_resp(conn, 200, "")
  end

  defp respond(conn, {:transport_error, reason}), do: Req.Test.transport_error(conn, reason)

  defp fetch(file, options \\ []) do
    options = Keyword.merge([plug: {Req.Test, @stub_name}, deadline_ms: @deadline_ms], options)
    Client.fetch(@system, file, options)
  end

  defp drop_feed(name, feed_name) do
    document = name |> fixture() |> JSON.decode!()
    feeds = Enum.reject(document["data"]["feeds"], &(&1["name"] == feed_name))
    {:body, 200, document |> put_in(["data", "feeds"], feeds) |> JSON.encode!()}
  end

  describe "fetch/3 of the vehicle file" do
    for {version, count} <- [{"3.0", 2}, {"2.2", 2}, {"1.0", 2}] do
      test "returns the vehicles of a feed that serves #{version} alone" do
        serve(routes(unquote(version)))

        assert {:ok, %{kind: :fetched, version: unquote(version), vehicles: vehicles}} =
                 fetch(:vehicle_status)

        assert length(vehicles) == unquote(count)
      end
    end

    test "prefers 3.0 when the feed serves every version" do
      serve(routes(["3.0", "2.2", "1.0"]))

      assert {:ok, %{kind: :fetched, version: "3.0", passed_over: []}} = fetch(:vehicle_status)
    end

    test "returns the vehicle file's last_updated and ttl" do
      serve(routes("3.0"))

      assert {:ok, %{last_updated: ~U[2026-11-08 19:07:58Z], ttl: 60}} = fetch(:vehicle_status)
    end

    test "returns the vehicle file's address and body as received" do
      serve(routes("3.0"))

      assert {:ok, %{url: @v3_vehicle_status, body: body}} = fetch(:vehicle_status)
      assert body == fixture("lime_v3_vehicle_status")
    end

    test "returns the time the clock gives when the vehicle file arrives" do
      serve(routes("3.0"))

      assert {:ok, %{fetched_at: ~U[2026-11-08 20:00:00Z]}} =
               fetch(:vehicle_status, clock: fn -> ~U[2026-11-08 20:00:00Z] end)
    end

    test "reads a body the server compresses with gzip" do
      serve(%{
        routes("3.0")
        | @v3_vehicle_status => {:gzip, fixture("lime_v3_vehicle_status")}
      })

      assert {:ok, %{version: "3.0", body: body}} = fetch(:vehicle_status)
      assert body == fixture("lime_v3_vehicle_status")
    end
  end

  describe "fetch/3 version fallback" do
    test "falls back to 2.2 when the 3.0 discovery file answers 404" do
      serve(routes(["2.2", "1.0"]))

      assert {:ok, %{version: "2.2", passed_over: passed_over}} = fetch(:vehicle_status)
      assert passed_over == [%{version: "3.0", reason: :discovery_not_found}]
    end

    test "falls back to 2.2 when the 3.0 discovery file drops the vehicle file" do
      serve(%{
        routes(["3.0", "2.2"])
        | @discovery_urls["3.0"] => drop_feed("lime_v3_gbfs", "vehicle_status")
      })

      assert {:ok, %{version: "2.2", passed_over: passed_over}} = fetch(:vehicle_status)
      assert passed_over == [%{version: "3.0", reason: :file_not_listed}]
    end

    test "falls back to 2.2 when the 3.0 vehicle file answers 404" do
      serve(Map.delete(routes(["3.0", "2.2"]), @v3_vehicle_status))

      assert {:ok, %{version: "2.2", passed_over: passed_over}} = fetch(:vehicle_status)
      assert passed_over == [%{version: "3.0", reason: :file_not_found}]
    end

    test "falls back to 1.0 when 3.0 and 2.2 are gone" do
      serve(routes("1.0"))

      assert {:ok, %{version: "1.0", passed_over: passed_over}} = fetch(:vehicle_status)

      assert passed_over == [
               %{version: "3.0", reason: :discovery_not_found},
               %{version: "2.2", reason: :discovery_not_found}
             ]
    end

    test "returns not_published when no version serves the vehicle file" do
      serve(%{})

      assert {:ok, %{kind: :not_published, passed_over: passed_over}} = fetch(:vehicle_status)
      assert Enum.map(passed_over, & &1.version) == ["3.0", "2.2", "1.0"]
    end

    test "tries only the versions the caller names" do
      serve(routes(["3.0", "2.2", "1.0"]))

      assert {:ok, %{version: "2.2", passed_over: []}} =
               fetch(:vehicle_status, versions: ["2.2"])
    end

    test "returns a 500 from 3.0 as a failure, with 2.2 untried" do
      serve(%{routes(["3.0", "2.2"]) | @discovery_urls["3.0"] => {:body, 500, ""}})

      assert fetch(:vehicle_status) ==
               {:error, %{cause: {:http_status, 500}, version: "3.0", file: :discovery}}
    end
  end

  describe "fetch/3 of vehicle_types" do
    for version <- ["3.0", "2.2"] do
      test "returns the types of a feed that serves #{version}" do
        serve(routes(unquote(version)))

        assert {:ok,
                %{kind: :fetched, version: unquote(version), vehicle_types: [_first | _rest]}} =
                 fetch(:vehicle_types)
      end
    end

    test "returns not_published for a feed that serves 1.0 alone, which has no vehicle_types" do
      serve(routes("1.0"))

      assert {:ok, %{kind: :not_published, passed_over: passed_over}} = fetch(:vehicle_types)

      assert passed_over == [
               %{version: "3.0", reason: :discovery_not_found},
               %{version: "2.2", reason: :discovery_not_found}
             ]
    end

    test "requests nothing of 1.0" do
      serve(routes("1.0"))

      {:ok, %{kind: :not_published}} = fetch(:vehicle_types)

      refute_received {:requested, "https://data.lime.bike/api/partners/v1/" <> _rest, _, _}
    end

    test "returns not_published when every version's optional file answers 404" do
      serve(Map.drop(routes(["3.0", "2.2"]), [@v3_vehicle_types, @v2_vehicle_types]))

      assert {:ok, %{kind: :not_published, passed_over: passed_over}} = fetch(:vehicle_types)

      assert passed_over == [
               %{version: "3.0", reason: :file_not_found},
               %{version: "2.2", reason: :file_not_found}
             ]
    end
  end

  describe "fetch/3 failures" do
    test "returns body_too_large for a body over the cap" do
      body = :binary.copy("a", Client.body_bytes_max() + 1)
      serve(%{routes("3.0") | @v3_vehicle_status => {:body, 200, body}})

      assert fetch(:vehicle_status) ==
               {:error, %{cause: :body_too_large, version: "3.0", file: :vehicle_status}}
    end

    test "returns body_too_large for a gzip body that expands past the cap" do
      body = :binary.copy("a", Client.body_bytes_max() + 1)
      serve(%{routes("3.0") | @v3_vehicle_status => {:gzip, body}})

      assert fetch(:vehicle_status) ==
               {:error, %{cause: :body_too_large, version: "3.0", file: :vehicle_status}}
    end

    test "returns deadline_exceeded when the deadline passes" do
      serve(%{routes("3.0") | @v3_vehicle_status => {:sleep, 1_000}})

      assert fetch(:vehicle_status, deadline_ms: 200) == {:error, %{cause: :deadline_exceeded}}
    end

    for {name, response, cause} <- [
          {"a 503", {:body, 503, ""}, {:http_status, 503}},
          {"a redirect", {:redirect, "https://elsewhere.example.test/"},
           {:unexpected_redirect, 302}},
          {"a body that is not JSON", {:body, 200, "<html></html>"}, :invalid_json},
          {"an encoding other than gzip", {:encoded, "br", "{}"}, {:unsupported_encoding, "br"}},
          {"a gzip body that is corrupt", {:encoded, "gzip", "not gzip"}, :corrupt_encoding},
          {"a network fault", {:transport_error, :econnrefused}, {:transport, :econnrefused}}
        ] do
      test "returns the cause for #{name}" do
        serve(%{routes("3.0") | @v3_vehicle_status => unquote(Macro.escape(response))})

        assert fetch(:vehicle_status) ==
                 {:error,
                  %{cause: unquote(Macro.escape(cause)), version: "3.0", file: :vehicle_status}}
      end
    end

    test "returns a schema mismatch for a vehicle file that breaks its version's format" do
      document = "lime_v3_vehicle_status" |> fixture() |> JSON.decode!()
      body = document |> Map.delete("ttl") |> JSON.encode!()
      serve(%{routes("3.0") | @v3_vehicle_status => {:body, 200, body}})

      assert fetch(:vehicle_status) ==
               {:error,
                %{
                  cause: {:schema_mismatch, %{path: ["ttl"], expected: :required}},
                  version: "3.0",
                  file: :vehicle_status
                }}
    end

    test "returns a schema mismatch for a discovery file that breaks its version's format" do
      serve(%{routes("3.0") | @discovery_urls["3.0"] => {:body, 200, ~s({"ttl": 0})}})

      assert {:error, %{cause: {:schema_mismatch, _mismatch}, version: "3.0", file: :discovery}} =
               fetch(:vehicle_status)
    end
  end

  describe "fetch/3 requests" do
    test "sends no query, no credentials, and no cookie" do
      serve(routes("3.0"))

      {:ok, %{kind: :fetched}} = fetch(:vehicle_status)

      assert_received {:requested, @v3_vehicle_status, headers, query_string}
      assert query_string == ""
      header_names = Enum.map(headers, &elem(&1, 0))
      refute "authorization" in header_names
      refute "cookie" in header_names
    end

    test "asks for JSON, compressed with gzip" do
      serve(routes("3.0"))

      {:ok, %{kind: :fetched}} = fetch(:vehicle_status)

      assert_received {:requested, @v3_vehicle_status, headers, _query_string}
      assert {"accept", "application/json"} in headers
      assert {"accept-encoding", "gzip"} in headers
    end
  end

  describe "fetch/3 arguments" do
    test "raises without a deadline" do
      assert_raise AssertionError, ~r/deadline_ms/, fn ->
        Client.fetch(@system, :vehicle_status, plug: {Req.Test, @stub_name})
      end
    end

    test "raises for a version the client does not read" do
      system = %{@system | discovery_urls: %{"2.3" => @discovery_urls["2.2"]}}

      assert_raise AssertionError, ~r/2\.3/, fn ->
        Client.fetch(system, :vehicle_status, deadline_ms: @deadline_ms)
      end
    end

    test "raises for a version the system does not name" do
      assert_raise AssertionError, ~r/4\.0/, fn ->
        fetch(:vehicle_status, versions: ["4.0"])
      end
    end

    test "raises for a discovery address that is not HTTPS" do
      system = %{@system | discovery_urls: %{"3.0" => "http://data.lime.bike/gbfs.json"}}

      assert_raise AssertionError, ~r/HTTPS/, fn ->
        Client.fetch(system, :vehicle_status, deadline_ms: @deadline_ms)
      end
    end
  end
end
