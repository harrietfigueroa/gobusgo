defmodule Gobusgo.VendorAssets.GithubTest do
  # Serves the request from a Req.Test stub and observes what fetch_archive/2
  # asks for and what it returns for each status.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.VendorAssets.Github

  @stub_name __MODULE__
  @options [plug: {Req.Test, @stub_name}, retry_delay_ms_base: 1]
  @commit String.duplicate("a", 40)
  @request %{repository: "protomaps/basemaps-assets", commit: @commit}

  defp stub_status(status, body) do
    recipient = self()

    Req.Test.stub(@stub_name, fn conn ->
      send(recipient, {:requested, conn.scheme, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  describe "fetch_archive/2" do
    test "returns the archive of the repository at the commit, from the archive host" do
      stub_status(200, "archive")

      assert Github.fetch_archive(@request, @options) == {:ok, "archive"}

      assert_received {:requested, :https, "codeload.github.com",
                       "/protomaps/basemaps-assets/tar.gz/" <> @commit}
    end

    test "returns :not_found for a 404" do
      stub_status(404, "404: Not Found")

      assert Github.fetch_archive(@request, @options) == {:error, :not_found}
    end

    for status <- [302, 403] do
      test "returns the status #{status} without following or retrying it" do
        stub_status(unquote(status), "")

        assert Github.fetch_archive(@request, @options) ==
                 {:error, {:http_status, unquote(status)}}

        assert_received {:requested, _scheme, _host, _path}
        refute_received {:requested, _scheme, _host, _path}
      end
    end

    for {description, request, pattern} <- [
          {"a commit that is a branch name",
           %{repository: "protomaps/basemaps-assets", commit: "main"}, ~r/commit/},
          {"a repository with a path",
           %{repository: "protomaps/../x", commit: String.duplicate("a", 40)}, ~r/repository/}
        ] do
      test "raises for #{description}" do
        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          Github.fetch_archive(unquote(Macro.escape(request)), @options)
        end
      end
    end
  end
end
