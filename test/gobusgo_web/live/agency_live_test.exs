defmodule GobusgoWeb.AgencyLiveTest do
  # Mounts the page with Phoenix.LiveViewTest and fills the application's
  # agency view with the record values AgencyBatch.Records builds. Each test
  # restarts that view, which is global state, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch.Records
  alias Gobusgo.OneBusAway.AgencyView

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  setup do
    restart_view()
    on_exit(&restart_view/0)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, AgencyView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, AgencyView)
  end

  defp agency(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "Agency #{id}",
        url: "https://agency-#{id}.example.test",
        timezone: "America/Los_Angeles",
        coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
      },
      overrides
    )
  end

  defp apply_fetch(agencies, overrides \\ %{}) do
    %{agencies: records, manifest: manifest} =
      Records.build(
        Map.merge(
          %{
            destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
            fetched_at: ~U[2026-10-02 03:15:00Z],
            data_sha256: String.duplicate("ab", 32),
            request_id: @request_id,
            agencies: agencies
          },
          overrides
        )
      )

    :ok = AgencyView.apply_records(AgencyView, Enum.map(records ++ [manifest], & &1.value))
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody tr")
    |> LazyHTML.attribute("id")
  end

  describe "GET /agencies without agency data" do
    test "says that no agency data is available yet" do
      {:ok, view, html} = live(build_conn(), "/agencies")

      assert html =~ "No agency data yet."
      refute has_element?(view, "table")
    end
  end

  describe "GET /agencies with agency data" do
    test "lists every agency of the current fetch in identifier order" do
      apply_fetch([agency("40"), agency("1")])

      {:ok, view, _html} = live(build_conn(), "/agencies")

      assert row_ids(view) == ["agency-1", "agency-40"]
    end

    test "shows the identifier, name, website, time zone, and coverage of an agency" do
      apply_fetch([agency("40")])

      {:ok, view, _html} = live(build_conn(), "/agencies")
      row = view |> element("#agency-40") |> render()

      assert row =~ "40"
      assert row =~ "Agency 40"
      assert row =~ ~s(href="https://agency-40.example.test")
      assert row =~ "America/Los_Angeles"
      assert row =~ "47.5, -122.25"
      assert row =~ "0.5 × 0.75"
    end

    test "shows the fetch the agencies come from" do
      apply_fetch([agency("1")])

      {:ok, view, _html} = live(build_conn(), "/agencies")
      fetch = view |> element("#fetch") |> render()

      assert fetch =~ "2026-10-02T03:15:00Z"
      assert fetch =~ @request_id
    end

    test "shows a website that is not an HTTP address as text, never as a link" do
      apply_fetch([agency("1", %{url: "javascript:alert(1)"})])

      {:ok, view, _html} = live(build_conn(), "/agencies")
      row = view |> element("#agency-1") |> render()

      assert row =~ "javascript:alert(1)"
      refute row =~ "href="
    end

    test "answers the first request with the agencies, before the socket connects" do
      apply_fetch([agency("1")])

      assert build_conn() |> get("/agencies") |> html_response(200) =~ "Agency 1"
    end
  end

  describe "an open page" do
    test "shows a fetch that completes after the page was opened" do
      {:ok, view, html} = live(build_conn(), "/agencies")
      assert html =~ "No agency data yet."

      apply_fetch([agency("1")])

      assert row_ids(view) == ["agency-1"]
    end

    test "drops an agency a later fetch no longer names" do
      apply_fetch([agency("1"), agency("40")])
      {:ok, view, _html} = live(build_conn(), "/agencies")

      apply_fetch([agency("1")], %{
        fetched_at: ~U[2026-10-02 03:16:00Z],
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
      })

      assert row_ids(view) == ["agency-1"]
      assert view |> element("#fetch") |> render() =~ "2026-10-02T03:16:00Z"
    end
  end
end
