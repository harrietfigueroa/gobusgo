defmodule GobusgoWeb.UsageHookTest do
  # Mounts pages with Phoenix.LiveViewTest while a usage recorder runs under
  # the name the hook registers with, writing under the test's temporary
  # directory. The name is global, hence the non-async case. Each test ends
  # a page's process, has the recorder write, and reads the record back
  # through the reader. Under test the application starts no recorder, so
  # every other test mounts its pages with none running. Phoenix.LiveViewTest
  # sets the `_mounts` parameter to 0 itself, so a reconnect is covered where
  # the parameter is read, in GobusgoWeb.ConnectionFactsTest.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.Reader
  alias Gobusgo.Schema
  alias Gobusgo.Usage
  alias Gobusgo.Usage.Records
  alias GobusgoWeb.UsageHook

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @prefix "usage/page-connections/"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

  defp start_recorder(%{tmp_dir: tmp_dir}) do
    start_supervised!({Usage, name: Usage, write_options: [base_dir: tmp_dir]})
    :ok
  end

  defp close(view) do
    reference = Process.monitor(view.pid)
    GenServer.stop(view.pid)
    assert_receive {:DOWN, ^reference, :process, _pid, _reason}
  end

  # The records of every connection that has ended, written now.
  defp records(%{tmp_dir: tmp_dir}) do
    {:ok, _record_count} = Usage.write(Usage)

    {:ok, %{destinations: destinations}} =
      Reader.discover(%{prefix: @prefix, limit: 100, order: :ascending, cursor: nil},
        base_dir: tmp_dir
      )

    Enum.flat_map(destinations, fn destination ->
      {:ok, content} = Reader.read(destination, base_dir: tmp_dir)
      JSON.decode!(content)["records"]
    end)
  end

  describe "page/1" do
    for {view, page} <- [
          {GobusgoWeb.HomeLive, "home"},
          {GobusgoWeb.AgencyLive, "agency"},
          {GobusgoWeb.VehicleLive, "vehicle"}
        ] do
      test "names #{inspect(view)} #{page}" do
        assert UsageHook.page(unquote(view)) == unquote(page)
      end
    end
  end

  describe "a connected page that ends" do
    setup :start_recorder

    for {path, page} <- [{"/", "home"}, {"/agencies", "agency"}, {"/vehicles", "vehicle"}] do
      test "leaves exactly one record for #{path}", context do
        {:ok, view, _html} = live(build_conn(), unquote(path))
        close(view)

        assert [%{"page" => unquote(page)}] = records(context)
      end
    end

    test "leaves a record that matches the schema and has no other field", context do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      close(view)

      assert [record] = records(context)
      assert Schema.mismatch(record, Records.schema()) == nil
      assert record |> Map.keys() |> Enum.sort() == Records.fields()
    end

    test "records what the browser connected with", context do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("user-agent", @iphone)
        |> put_connect_params(%{
          "_mounts" => 0,
          "client" => %{
            "viewport_width" => 390,
            "language" => "es-MX",
            "referrer_host" => "example.org"
          }
        })

      {:ok, view, _html} = live(conn, "/vehicles")
      close(view)

      assert [
               %{
                 "reconnect" => false,
                 "deviceClass" => "mobile",
                 "browserFamily" => "safari",
                 "viewportWidthBucket" => "under-480",
                 "language" => "es",
                 "referrerHost" => "example.org"
               }
             ] = records(context)
    end

    test "keeps nothing of the user agent or of a referrer's path", context do
      conn =
        build_conn()
        |> Plug.Conn.put_req_header("user-agent", @iphone)
        |> put_connect_params(%{"client" => %{"referrer_host" => "example.org/secret?q=1"}})

      {:ok, view, _html} = live(conn, "/vehicles")
      close(view)

      assert [record] = records(context)
      encoded = JSON.encode!(record)

      refute encoded =~ "Mozilla"
      refute encoded =~ "iPhone OS"
      refute encoded =~ "secret"
    end

    test "holds no referrer host for a visit from the page's own host", context do
      conn =
        put_connect_params(build_conn(), %{"client" => %{"referrer_host" => "www.example.com"}})

      {:ok, view, _html} = live(conn, "/vehicles")
      close(view)

      assert [%{"referrerHost" => nil}] = records(context)
    end

    test "mounts and records nil for parameters outside their rules", context do
      conn =
        put_connect_params(build_conn(), %{
          "client" => %{
            "viewport_width" => "wide",
            "language" => "<script>",
            "referrer_host" => "https://example.org/a"
          }
        })

      {:ok, view, _html} = live(conn, "/vehicles")
      close(view)

      assert [
               %{
                 "viewportWidthBucket" => nil,
                 "language" => nil,
                 "referrerHost" => nil
               }
             ] = records(context)
    end
  end

  describe "the vehicle page" do
    setup :start_recorder

    test "has its record hold the filter of its address", context do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=1,40&route=40_100479")
      close(view)

      assert [%{"filter" => %{"agency" => ["1", "40"], "route" => ["40_100479"]}}] =
               records(context)
    end

    test "has its record hold the last filter it showed", context do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=1")
      render_patch(view, "/vehicles?agency=40")
      close(view)

      assert [%{"filter" => %{"agency" => ["40"]}}] = records(context)
    end

    test "keeps the last filter it showed when the address holds a refused one", context do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=1")
      render_patch(view, "/vehicles?agency[x]=1")
      close(view)

      assert [%{"filter" => %{"agency" => ["1"]}}] = records(context)
    end

    test "has its record hold no filter when it showed every vehicle", context do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      close(view)

      assert [%{"filter" => filter, "filterValueOmittedCount" => 0}] = records(context)
      assert filter == %{}
    end
  end

  describe "the static render" do
    setup :start_recorder

    test "registers nothing", context do
      assert build_conn() |> get("/vehicles") |> html_response(200) =~ "app-info"

      assert records(context) == []
    end
  end

  describe "a page with no recorder running" do
    test "mounts" do
      assert Process.whereis(Usage) == nil

      assert {:ok, _view, html} = live(build_conn(), "/vehicles")
      assert html =~ "app-info"
    end
  end

  describe "a page the recorder refuses" do
    test "mounts, and leaves no record", context do
      start_supervised!(
        {Usage, name: Usage, open_count_max: 1, write_options: [base_dir: context.tmp_dir]}
      )

      {:ok, first, _html} = live(build_conn(), "/")
      assert {:ok, second, _html} = live(build_conn(), "/vehicles")
      close(second)
      close(first)

      assert [%{"page" => "home"}] = records(context)
    end
  end
end
