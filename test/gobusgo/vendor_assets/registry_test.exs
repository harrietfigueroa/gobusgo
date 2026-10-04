defmodule Gobusgo.VendorAssets.RegistryTest do
  # Serves each request from a Req.Test stub and observes what the registry
  # functions return for the statuses, bodies, and faults a registry can
  # answer with, and how many attempts each takes.
  use ExUnit.Case, async: true

  alias Gobusgo.VendorAssets.Registry

  @stub_name __MODULE__
  @options [plug: {Req.Test, @stub_name}, retry_delay_ms_base: 1]
  @integrity "sha512-" <> Base.encode64(String.duplicate(<<1>>, 64))
  @tarball_url "https://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz"
  @metadata %{
    "name" => "pmtiles",
    "version" => "4.5.0",
    "dist" => %{"tarball" => @tarball_url, "integrity" => @integrity}
  }

  # Serves each {status, body} once, in order, and counts the attempts.
  defp stub_responses(responses) do
    attempts = :counters.new(1, [])
    recipient = self()

    Req.Test.stub(@stub_name, fn conn ->
      :counters.add(attempts, 1, 1)
      send(recipient, {:requested, conn.host, conn.request_path})
      {status, body} = Enum.at(responses, :counters.get(attempts, 1) - 1)
      Plug.Conn.send_resp(conn, status, body)
    end)

    attempts
  end

  defp fetch_version(version \\ :latest) do
    Registry.fetch_version(%{name: "pmtiles", version: version}, @options)
  end

  describe "fetch_version/2" do
    test "returns the version, the tarball address, and the integrity the latest tag names" do
      stub_responses([{200, JSON.encode!(@metadata)}])

      assert fetch_version() ==
               {:ok, %{version: "4.5.0", tarball: @tarball_url, integrity: @integrity}}

      assert_received {:requested, "registry.npmjs.org", "/pmtiles/latest"}
    end

    test "asks for a version by its number" do
      stub_responses([{200, JSON.encode!(@metadata)}])

      assert {:ok, %{version: "4.5.0"}} = fetch_version("4.5.0")
      assert_received {:requested, "registry.npmjs.org", "/pmtiles/4.5.0"}
    end

    test "asks for a scoped package under its scope" do
      metadata = %{
        @metadata
        | "name" => "@protomaps/basemaps",
          "dist" => %{
            "tarball" => "https://registry.npmjs.org/@protomaps/basemaps/-/basemaps-4.5.0.tgz",
            "integrity" => @integrity
          }
      }

      stub_responses([{200, JSON.encode!(metadata)}])

      assert {:ok, _version} =
               Registry.fetch_version(%{name: "@protomaps/basemaps", version: :latest}, @options)

      assert_received {:requested, "registry.npmjs.org", "/@protomaps/basemaps/latest"}
    end

    test "returns :not_found for a 404 and does not retry" do
      attempts = stub_responses([{404, ~s("version not found: 99.0.0")}])

      assert fetch_version("99.0.0") == {:error, :not_found}
      assert :counters.get(attempts, 1) == 1
    end

    test "returns :invalid_json for a body that is not JSON" do
      stub_responses([{200, "<html>"}])

      assert fetch_version() == {:error, :invalid_json}
    end

    for {description, change} <- [
          {"another package's name", %{"name" => "other"}},
          {"no integrity",
           %{"dist" => %{"tarball" => "https://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz"}}},
          {"a tarball on another host",
           %{
             "dist" => %{
               "tarball" => "https://example.test/pmtiles-4.5.0.tgz",
               "integrity" => "sha512-" <> Base.encode64(String.duplicate(<<1>>, 64))
             }
           }},
          {"a version that is not a number", %{"version" => "../x"}}
        ] do
      test "returns :invalid_metadata for metadata with #{description}" do
        stub_responses([{200, JSON.encode!(Map.merge(@metadata, unquote(Macro.escape(change))))}])

        assert fetch_version() == {:error, :invalid_metadata}
      end
    end

    test "returns :body_too_large for metadata past its bound" do
      stub_responses([{200, String.duplicate("a", 1_048_577)}])

      assert fetch_version() == {:error, :body_too_large}
    end
  end

  describe "fetch_tarball/2" do
    test "returns the bytes of the tarball" do
      stub_responses([{200, <<31, 139, 0, 255>>}])

      assert Registry.fetch_tarball(@tarball_url, @options) == {:ok, <<31, 139, 0, 255>>}
      assert_received {:requested, "registry.npmjs.org", "/pmtiles/-/pmtiles-4.5.0.tgz"}
    end

    test "retries a transient status and returns the later success" do
      attempts = stub_responses([{503, ""}, {500, ""}, {200, "tarball"}])

      assert Registry.fetch_tarball(@tarball_url, @options) == {:ok, "tarball"}
      assert :counters.get(attempts, 1) == 3
    end

    test "returns the status after three attempts" do
      attempts = stub_responses([{503, ""}, {503, ""}, {503, ""}])

      assert Registry.fetch_tarball(@tarball_url, @options) == {:error, {:http_status, 503}}
      assert :counters.get(attempts, 1) == 3
    end

    test "returns a client error status without a retry" do
      attempts = stub_responses([{403, ""}])

      assert Registry.fetch_tarball(@tarball_url, @options) == {:error, {:http_status, 403}}
      assert :counters.get(attempts, 1) == 1
    end

    test "returns a redirect as its status and does not follow it" do
      attempts = stub_responses([{302, ""}])

      assert Registry.fetch_tarball(@tarball_url, @options) == {:error, {:http_status, 302}}
      assert :counters.get(attempts, 1) == 1
    end

    test "returns the transport fault after three attempts" do
      attempts = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(attempts, 1, 1)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Registry.fetch_tarball(@tarball_url, @options) ==
               {:error, {:transport, :econnrefused}}

      assert :counters.get(attempts, 1) == 3
    end
  end
end
