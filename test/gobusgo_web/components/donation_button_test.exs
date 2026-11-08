defmodule GobusgoWeb.DonationButtonTest do
  # Mounts each browser page with Phoenix.LiveViewTest, with the donation
  # address set and unset, and reads the donation button and the donation
  # section of the Settings tab's About group. The address and the basemap
  # directory are application configuration, global state, hence the
  # non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias GobusgoWeb.AppInfo

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @donation_url "https://ko-fi.com/harrietwaters"
  @button "a#donation-button"
  @section "#app-info-about #app-info-donation"
  @paths ["/", "/agencies", "/vehicles"]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }

  setup %{tmp_dir: tmp_dir} do
    configured_donation = Application.get_env(:gobusgo, :donation)
    configured_basemap = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)

    on_exit(fn ->
      Application.put_env(:gobusgo, :donation, configured_donation)
      Application.put_env(:gobusgo, :basemap, configured_basemap)
    end)
  end

  defp set_donation_url(url), do: Application.put_env(:gobusgo, :donation, url: url)

  defp attribute(view, selector, name) do
    [value] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(name)

    value
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()
  end

  for path <- @paths do
    describe "the donation button on #{path}" do
      test "is one link to the configured address" do
        set_donation_url(@donation_url)
        {:ok, view, _html} = live(build_conn(), unquote(path))

        assert count(view, ~s{a[href="#{@donation_url}"]:not(#app-info-donation-link)}) == 1
        assert attribute(view, @button, "href") == @donation_url
      end

      test "opens in a new tab with no opener and no referrer" do
        set_donation_url(@donation_url)
        {:ok, view, _html} = live(build_conn(), unquote(path))

        assert attribute(view, @button, "target") == "_blank"
        assert attribute(view, @button, "rel") == "noopener noreferrer"
      end

      test "is named Support gobusgo on Ko-fi" do
        set_donation_url(@donation_url)
        {:ok, view, _html} = live(build_conn(), unquote(path))

        assert attribute(view, @button, "aria-label") == "Support gobusgo on Ko-fi"
      end

      test "draws its symbol hidden from assistive technology" do
        set_donation_url(@donation_url)
        {:ok, view, _html} = live(build_conn(), unquote(path))

        assert has_element?(view, @button <> " svg[aria-hidden=true]")
      end

      for {description, url} <- [{"an unset address", nil}, {"a blank address", "  "}] do
        test "is absent for #{description}" do
          set_donation_url(unquote(url))
          {:ok, view, _html} = live(build_conn(), unquote(path))

          refute has_element?(view, @button)
        end
      end
    end
  end

  describe "the donation button on /vehicles with a basemap" do
    test "is one link to the configured address", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
      set_donation_url(@donation_url)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "[phx-hook=Basemap]")
      assert count(view, @button) == 1
      assert attribute(view, @button, "href") == @donation_url
    end
  end

  describe "the donation section of the About group" do
    test "says what donations fund" do
      set_donation_url(@donation_url)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@section) |> render() =~ AppInfo.donation()
    end

    test "links the configured address in a new tab" do
      set_donation_url(@donation_url)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      link = @section <> " a#app-info-donation-link"
      assert attribute(view, link, "href") == @donation_url
      assert attribute(view, link, "target") == "_blank"
      assert attribute(view, link, "rel") == "noopener noreferrer"
    end

    test "names no agency of the agency view" do
      apply_agencies([{"1", "King County Metro"}, {"40", "Sound Transit"}])
      on_exit(&restart_agency_view/0)
      set_donation_url(@donation_url)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text = view |> element(@section) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
      refute text =~ "King County Metro"
      refute text =~ "Sound Transit"
    end

    for {description, url} <- [{"an unset address", nil}, {"a blank address", "  "}] do
      test "is absent for #{description}" do
        set_donation_url(unquote(url))
        {:ok, view, _html} = live(build_conn(), "/vehicles")

        assert has_element?(view, "#app-info-about")
        refute has_element?(view, "#app-info-donation")
      end
    end
  end

  defp restart_agency_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, AgencyView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, AgencyView)
  end

  # Publishes a fetch of agencies, each `{id, name}`.
  defp apply_agencies(agencies) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
        fetched_at: ~U[2026-10-02 03:15:00Z],
        data_sha256: String.duplicate("ab", 32),
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000000",
        agencies:
          for {id, name} <- agencies do
            %{
              id: id,
              name: name,
              url: "https://agency-#{id}.example.test",
              timezone: "America/Los_Angeles",
              coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
            }
          end
      })

    :ok = AgencyView.apply_records(AgencyView, Enum.map(records ++ [manifest], & &1.value))
  end
end
