defmodule Gobusgo.Basemap.ExtractorTest do
  # Drives run/2 through a reader double and a runner double defined here, so
  # every outcome is observed with no stored file and no extraction tool: the
  # runner double writes the archive the tool would write. Output goes to the
  # test's temporary directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Basemap.Extractor
  alias Gobusgo.OneBusAway.RawAgencyResponse

  @moduletag :tmp_dir

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  @snapshot "20261004"
  @archive_content "archive bytes"
  @west {"west", {10.0, 10.0, 2.0, 2.0}}
  @east {"east", {10.0, 30.0, 2.0, 2.0}}
  @missing {"missing", {0.0, 0.0, 0.0, 0.0}}

  defp raw(agencies) do
    data = %{
      "limitExceeded" => false,
      "list" =>
        for {id, {lat, lon, lat_span, lon_span}} <- agencies do
          %{
            "agencyId" => id,
            "lat" => lat,
            "lon" => lon,
            "latSpan" => lat_span,
            "lonSpan" => lon_span
          }
        end,
      "references" => %{
        "agencies" =>
          for {id, _coverage} <- agencies do
            %{
              "id" => id,
              "name" => "Agency #{id}",
              "url" => "https://agency.example.test",
              "timezone" => "America/Los_Angeles"
            }
          end
      }
    }

    response = %{
      agencies: [],
      envelope: %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => data,
        "text" => "OK",
        "version" => 2
      },
      fetched_at: ~U[2026-10-03 19:10:46Z],
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawAgencyResponse.build(%{
      response: response,
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001"
    })
  end

  # The runner double: reports each call to the test and writes the archive
  # at the output path, the third argument of an extraction.
  defp writing_runner do
    recipient = self()

    fn ["extract", _source_url, output_path | _flags] = arguments, deadline_ms ->
      send(recipient, {:ran, arguments, deadline_ms})
      File.write!(output_path, @archive_content)
      :ok
    end
  end

  defp run(agencies, tmp_dir, overrides \\ []) do
    %{destination: destination, content: content} = raw(agencies)

    options =
      Keyword.merge(
        [
          backend: StoredContent,
          stored: %{destination => Gobusgo.Compression.compress(content)},
          runner: writing_runner()
        ],
        overrides
      )

    request =
      Map.merge(
        %{response_destination: destination, snapshot: @snapshot, output_dir: tmp_dir},
        Keyword.get(overrides, :request, %{})
      )

    {destination, Extractor.run(request, Keyword.delete(options, :request))}
  end

  describe "run/2" do
    test "extracts one archive per region into the output directory", %{tmp_dir: tmp_dir} do
      {_destination, result} = run([@east, @west, @missing], tmp_dir)

      assert {:ok, %{archives: archives}} = result

      assert archives == [
               %{
                 path: Path.join(tmp_dir, "basemap-20261004-01.pmtiles"),
                 bytes: byte_size(@archive_content)
               },
               %{
                 path: Path.join(tmp_dir, "basemap-20261004-02.pmtiles"),
                 bytes: byte_size(@archive_content)
               }
             ]

      for %{path: path} <- archives, do: assert(File.read!(path) == @archive_content)
    end

    test "runs the extraction of each archive with a deadline", %{tmp_dir: tmp_dir} do
      run([@west], tmp_dir)

      assert_received {:ran,
                       ["extract", source_url, _output_path, "--bbox=" <> _bbox, "--maxzoom=15"],
                       deadline_ms}

      assert source_url == "https://build.protomaps.com/20261004.pmtiles"
      assert deadline_ms > 0
    end

    test "leaves no partial file beside a finished archive", %{tmp_dir: tmp_dir} do
      run([@west], tmp_dir)

      assert Enum.sort(File.ls!(tmp_dir)) == ["basemap-20261004-01.pmtiles", "manifest.json"]
    end

    test "writes the manifest of the run", %{tmp_dir: tmp_dir} do
      {destination, {:ok, %{manifest_path: manifest_path}}} = run([@west, @missing], tmp_dir)

      assert manifest_path == Path.join(tmp_dir, "manifest.json")

      assert %{
               "snapshot" => "20261004",
               "sourceResponse" => ^destination,
               "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bytes" => 13}],
               "agencies" => [%{"agencyId" => "west", "archive" => "basemap-20261004-01.pmtiles"}],
               "skipped" => [%{"agencyId" => "missing", "reason" => "coverage_missing"}]
             } = manifest_path |> File.read!() |> JSON.decode!()
    end

    test "returns the agencies it skipped", %{tmp_dir: tmp_dir} do
      {_destination, {:ok, %{skipped: skipped}}} = run([@west, @missing], tmp_dir)

      assert skipped == [%{agency_id: "missing", reason: :coverage_missing}]
    end

    test "creates the output directory", %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "basemap/new")

      assert {_destination, {:ok, _extracted}} =
               run([@west], tmp_dir, request: %{output_dir: output_dir})

      assert File.exists?(Path.join(output_dir, "manifest.json"))
    end

    test "replaces the archive of an earlier run", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "basemap-20261004-01.pmtiles"), "an earlier archive")

      assert {_destination, {:ok, %{archives: [%{path: path}]}}} = run([@west], tmp_dir)
      assert File.read!(path) == @archive_content
    end

    test "returns a snapshot that is not a build date and runs nothing", %{tmp_dir: tmp_dir} do
      {_destination, result} = run([@west], tmp_dir, request: %{snapshot: "latest"})

      assert result == {:error, {:invalid_snapshot, "latest"}}
      refute_received {:ran, _arguments, _deadline_ms}
    end

    test "returns the reader's failure", %{tmp_dir: tmp_dir} do
      {_destination, result} = run([@west], tmp_dir, stored: %{})

      assert result == {:error, {:read, :not_found}}
    end

    test "returns the reason a stored response is rejected", %{tmp_dir: tmp_dir} do
      %{destination: destination} = raw([@west])
      stored = %{destination => Gobusgo.Compression.compress("not json")}

      assert {_destination, {:error, {:parse, :invalid_json}}} =
               run([@west], tmp_dir, stored: stored)
    end

    test "returns :no_region when no agency has coverage", %{tmp_dir: tmp_dir} do
      {_destination, result} = run([@missing], tmp_dir)

      assert result == {:error, :no_region}
      assert File.ls!(tmp_dir) == []
    end

    test "returns the runner's failure with the archive it was extracting", %{tmp_dir: tmp_dir} do
      runner = fn _arguments, _deadline_ms -> {:error, {:exit_status, 1}} end

      {_destination, result} = run([@west], tmp_dir, runner: runner)

      assert result == {:error, {:extract, "basemap-20261004-01.pmtiles", {:exit_status, 1}}}
      assert File.ls!(tmp_dir) == []
    end

    test "removes the partial file of a failed extraction", %{tmp_dir: tmp_dir} do
      runner = fn ["extract", _source_url, output_path | _flags], _deadline_ms ->
        File.write!(output_path, "half an archive")
        {:error, :deadline_exceeded}
      end

      {_destination, result} = run([@west], tmp_dir, runner: runner)

      assert result == {:error, {:extract, "basemap-20261004-01.pmtiles", :deadline_exceeded}}
      assert File.ls!(tmp_dir) == []
    end

    test "returns :archive_missing when the runner writes no archive", %{tmp_dir: tmp_dir} do
      runner = fn _arguments, _deadline_ms -> :ok end

      {_destination, result} = run([@west], tmp_dir, runner: runner)

      assert result == {:error, {:extract, "basemap-20261004-01.pmtiles", :archive_missing}}
    end
  end
end
