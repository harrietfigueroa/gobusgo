defmodule GobusgoWeb.RenderedPagesTest do
  # Renders each browser page and state the server renders, checks it
  # against Gobusgo.Test.Accessibility, and writes it to tools/lint/rendered/ for
  # html-eslint, which reads the files in the accessibility CI job. The
  # vehicle page with a basemap reads a manifest the test writes to its
  # temporary directory and names as the basemap directory, hence the
  # non-async case. What the browser builds after it connects is not here.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Gobusgo.Test.Accessibility

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @output_dir Path.expand("../../../tools/lint/rendered", __DIR__)
  @archive "basemap-20261004-01.pmtiles"
  @bounds %{"south" => 9.0, "west" => 9.0, "north" => 12.0, "east" => 12.5}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => @archive, "bounds" => @bounds}],
    "agencies" => [%{"agencyId" => "1", "archive" => @archive, "bounds" => @bounds}]
  }

  # The rules each page still breaks, each with the issue that fixes it. A
  # page must still break every rule it lists, so the fix removes its entry.
  @known_failures %{
    "error-404" => %{main: "GOB-309"},
    "error-500" => %{main: "GOB-309"}
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)
    File.mkdir_p!(@output_dir)
    :ok
  end

  defp write_manifest(tmp_dir) do
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
  end

  # Writes the page for html-eslint and checks it here, less its known
  # failures.
  defp check(name, html) do
    File.write!(Path.join(@output_dir, name <> ".html"), html)
    known = Map.get(@known_failures, name, %{})
    violations = Accessibility.violations(html)
    {listed, unlisted} = Enum.split_with(violations, &known_failure?(known, &1))
    listed_rules = listed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

    assert unlisted == []
    assert listed_rules == known |> Map.keys() |> Enum.sort()
  end

  defp known_failure?(known, {rule, _detail}), do: Map.has_key?(known, rule)

  defp page(path), do: build_conn() |> get(path) |> html_response(200)

  test "the home page" do
    check("home", page("/"))
  end

  test "the agencies page" do
    check("agencies", page("/agencies"))
  end

  test "the vehicle page without a basemap" do
    check("vehicles-no-basemap", page("/vehicles"))
  end

  describe "the vehicle page with a basemap" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
    end

    test "with no filter" do
      check("vehicles", page("/vehicles"))
    end

    test "with a filter by agency and route" do
      check("vehicles-filtered", page("/vehicles?agency=1&route=1_100479"))
    end

    test "with a refused filter" do
      check("vehicles-refused-filter", page("/vehicles?agency[x]=1"))
    end
  end

  for status <- [404, 500] do
    test "the #{status} error page" do
      html =
        "#{unquote(status)}.html"
        |> GobusgoWeb.ErrorHTML.render(%{status: unquote(status)})
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      check("error-#{unquote(status)}", html)
    end
  end
end
