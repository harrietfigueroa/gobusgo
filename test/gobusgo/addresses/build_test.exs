defmodule Gobusgo.Addresses.BuildTest do
  # Drives run/1 against an addresses process, a source
  # defined in test/support, and the local file writer and reader over a
  # temporary directory. What a run built is read from the manifest the
  # process holds, the files in the directory, and the returned outcome.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses
  alias Gobusgo.Addresses.Build
  alias Gobusgo.Addresses.Format
  alias Gobusgo.Addresses.Rows
  alias Gobusgo.Packed
  alias Gobusgo.Test.AddressSource
  alias Gobusgo.Test.AddressSourceTwo

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @now ~U[2026-11-10 12:00:00Z]
  @bounds %{south: 47.0, west: -123.0, north: 48.0, east: -121.0}

  defmodule FailingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(_request, _options), do: {:error, :io_failure}
  end

  setup %{tmp_dir: tmp_dir, line: line} do
    server = Module.concat(__MODULE__, "Addresses#{line}")
    start_supervised!({Addresses, name: server, read_options: [base_dir: tmp_dir]})
    %{server: server, tmp_dir: tmp_dir}
  end

  defp record(overrides) do
    Map.merge(
      %{
        house_number: "85",
        pre_direction: "",
        name: "PIKE",
        type: "ST",
        suf_direction: "",
        city: "SEATTLE",
        lat: 47.6097,
        lon: -122.3422
      },
      Map.new(overrides)
    )
  end

  defp records do
    [
      record(house_number: "85"),
      record(house_number: "87", lat: 47.6098),
      record(name: "PINE", house_number: "500"),
      record(name: "PINE", house_number: "502", city: "KENT"),
      record(name: "ELM", house_number: "9", lat: 40.0, lon: -100.0)
    ]
  end

  defp run(%{server: server, tmp_dir: tmp_dir} = context, overrides \\ []) do
    options =
      Keyword.merge(
        [
          server: server,
          sources: [{AddressSource, [records: Map.get(context, :records, records())]}],
          bounds: {:bounds, @bounds},
          clock: fn -> Map.get(context, :now, @now) end,
          write_options: [base_dir: tmp_dir],
          work_directory: Path.join(tmp_dir, "work")
        ],
        overrides
      )

    Build.run(options)
  end

  defp stored_files(tmp_dir) do
    tmp_dir
    |> Path.join("addresses/**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, tmp_dir))
    |> Enum.sort()
  end

  test "builds the shards, the index, and the manifest that names them", context do
    assert run(context) == {:ok, %{outcome: :built}}

    assert {:ok, manifest} = Addresses.manifest(context.server)
    assert manifest["addressCount"] == 4
    assert manifest["streetCount"] == 3
    assert manifest["sourceLastEditAt"] == "2026-11-09T12:00:00Z"

    named = [manifest["index"] | manifest["shards"]]

    for %{"path" => "/" <> destination, "byteSize" => byte_size, "sha256" => sha256} <- named do
      assert String.starts_with?(destination, "addresses/dt=2026-11-10/")
      stream = File.read!(Path.join(context.tmp_dir, destination))
      assert byte_size(stream) == byte_size
      assert Base.encode16(:crypto.hash(:sha256, stream), case: :lower) == sha256
      assert destination =~ sha256
    end

    files = stored_files(context.tmp_dir)
    assert Enum.count(files, &String.contains?(&1, "/manifest-")) == 1
    assert length(files) == length(named) + 1
  end

  test "stores an index and shards a reader decodes to the addresses that were accepted",
       %{tmp_dir: tmp_dir} = context do
    run(context)
    {:ok, manifest} = Addresses.manifest(context.server)

    index_stream =
      File.read!(Path.join(tmp_dir, String.trim_leading(manifest["index"]["path"], "/")))

    {:ok, index_content} = Packed.expand(index_stream, Format.expanded_bytes_max(:index))
    assert {:ok, %{entries: entries}} = Format.decode_index(index_content)
    assert Enum.map(entries, & &1.sha256) == Enum.map(manifest["shards"], & &1["sha256"])
    assert Enum.map(entries, & &1.byte_size) == Enum.map(manifest["shards"], & &1["byteSize"])

    decoded =
      for entry <- entries do
        stream = File.read!(Path.join([tmp_dir, "addresses/dt=2026-11-10", entry.name]))
        {:ok, content} = Packed.expand(stream, Format.expanded_bytes_max(:shard))
        {:ok, %{streets: streets}} = Format.decode_shard(content)
        streets
      end

    addresses =
      for street <- Enum.concat(decoded), address <- Rows.unpack(street.rows) do
        {street.street.name, street.city, address.number}
      end

    assert Enum.sort(addresses) == [
             {"PIKE", "SEATTLE", 85},
             {"PIKE", "SEATTLE", 87},
             {"PINE", "KENT", 502},
             {"PINE", "SEATTLE", 500}
           ]
  end

  test "names each file by its prefix and the hash of its stream",
       %{tmp_dir: tmp_dir} = context do
    run(context)
    {:ok, manifest} = Addresses.manifest(context.server)

    for %{"path" => path, "sha256" => sha256} <- [manifest["index"] | manifest["shards"]] do
      assert path =~ ~r{/(addresses|addresses-index)-#{sha256}\.bin\.gz\z}
      assert File.exists?(Path.join(tmp_dir, String.trim_leading(path, "/")))
    end
  end

  test "leaves out the addresses outside the bounds and says how many", context do
    run(context)
    assert {:ok, %{"addressCount" => 4}} = Addresses.manifest(context.server)
  end

  test "keeps every address with no bounds", context do
    assert {:ok, _outcome} = run(context, bounds: :none)
    assert {:ok, %{"addressCount" => 5}} = Addresses.manifest(context.server)
  end

  test "a second run of the same day over the same input builds nothing", context do
    run(context)
    before = stored_files(context.tmp_dir)

    assert run(context) == {:ok, %{outcome: :unchanged}}
    assert stored_files(context.tmp_dir) == before
  end

  test "a run on a later day over the same input writes the same names under that day", context do
    run(context)
    names = fn files -> Enum.map(files, &Path.basename/1) end

    first_names =
      context.tmp_dir |> stored_files() |> names.() |> Enum.reject(&(&1 =~ "manifest-"))

    assert run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z])) == {:ok, %{outcome: :built}}

    later_names =
      context.tmp_dir
      |> stored_files()
      |> Enum.filter(&String.contains?(&1, "dt=2026-11-11"))
      |> names.()
      |> Enum.reject(&(&1 =~ "manifest-"))

    assert later_names == first_names
    assert {:ok, %{built_on: ~D[2026-11-11]}} = Addresses.built(context.server)
  end

  test "a changed address gives other names and a new manifest", context do
    run(context)
    {:ok, first} = Addresses.manifest(context.server)
    changed = List.replace_at(records(), 0, record(house_number: "85", lat: 47.61))

    assert run(Map.put(context, :records, changed)) == {:ok, %{outcome: :built}}
    {:ok, second} = Addresses.manifest(context.server)

    refute second["inputsSha256"] == first["inputsSha256"]
    refute second["shards"] == first["shards"]
  end

  test "a stale export keeps the current build and writes nothing", context do
    run(context)
    before = stored_files(context.tmp_dir)
    {:ok, current} = Addresses.manifest(context.server)

    stale = %{
      reason: :export_older_than_layer,
      layer_last_edit_at: ~U[2026-11-10 08:00:00Z],
      layer_record_count: 5
    }

    result =
      run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z]),
        sources: [{AddressSource, [answer: {:stale, stale}]}]
      )

    assert result == {:ok, %{outcome: :stale}}
    assert stored_files(context.tmp_dir) == before
    assert Addresses.manifest(context.server) == {:ok, current}
  end

  test "a failed fetch is an error and keeps the current build", context do
    run(context)
    {:ok, current} = Addresses.manifest(context.server)

    result =
      run(context, sources: [{AddressSource, [answer: {:error, {:transport, :timeout}}]}])

    assert result == {:error, {:fetch, :test, {:transport, :timeout}}}
    assert Addresses.manifest(context.server) == {:ok, current}
  end

  test "records fewer than the layer's count are an error and write nothing", context do
    result = run(context, sources: [{AddressSource, [records: records(), record_count: 6]}])

    assert result == {:error, {:record_count_differs, :test, 5, 6}}
    assert stored_files(context.tmp_dir) == []
    assert Addresses.manifest(context.server) == :none
  end

  test "a failed write is an error and records no manifest", context do
    result = run(context, write_options: [backend: FailingBackend])

    assert result == {:error, {:write, :io_failure}}
    assert Addresses.manifest(context.server) == :none
  end

  test "a build that outgrows its heap cap is killed and records no manifest", context do
    assert run(context, heap_words_max: 2_000) == {:error, :killed}
    assert Addresses.manifest(context.server) == :none
    assert stored_files(context.tmp_dir) == []
  end

  describe "with more than one source" do
    defp second_records do
      [
        record(name: "MARKET", house_number: "747", city: "TACOMA", lat: 47.25, lon: -122.44),
        record(name: "PINE", house_number: "504", lat: 47.6098, lon: -122.3423),
        record(house_number: "99", is_active: false)
      ]
    end

    defp two_sources(first_options \\ [], second_options \\ []) do
      [
        {AddressSource, Keyword.merge([records: records()], first_options)},
        {AddressSourceTwo, Keyword.merge([records: second_records()], second_options)}
      ]
    end

    test "publishes one set of files that holds the addresses of both", context do
      assert run(context, sources: two_sources()) == {:ok, %{outcome: :built}}

      assert {:ok, manifest} = Addresses.manifest(context.server)
      assert manifest["addressCount"] == 6
      assert manifest["streetCount"] == 4
    end

    test "names each source, its last edit, and its count of records in the manifest, and the newest edit as the build's",
         context do
      sources = two_sources([], last_edit_at: ~U[2026-11-10 06:00:00Z])

      run(context, sources: sources)
      {:ok, manifest} = Addresses.manifest(context.server)

      assert manifest["sourceLastEditAt"] == "2026-11-10T06:00:00Z"

      assert manifest["sources"] == [
               %{"name" => "test", "lastEditAt" => "2026-11-09T12:00:00Z", "recordCount" => 5},
               %{"name" => "test_two", "lastEditAt" => "2026-11-10T06:00:00Z", "recordCount" => 3}
             ]
    end

    test "the order of the sources does not change what is built", context do
      run(context, sources: two_sources())
      {:ok, first} = Addresses.manifest(context.server)

      reversed = Enum.reverse(two_sources())
      run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z]), sources: reversed)
      {:ok, second} = Addresses.manifest(context.server)

      assert second["inputsSha256"] == first["inputsSha256"]

      assert Enum.map(second["shards"], & &1["sha256"]) ==
               Enum.map(first["shards"], & &1["sha256"])
    end

    test "a stale export of the second source keeps the current build and writes nothing",
         context do
      run(context, sources: two_sources())
      before = stored_files(context.tmp_dir)
      {:ok, current} = Addresses.manifest(context.server)

      stale = %{
        reason: :export_older_than_layer,
        layer_last_edit_at: ~U[2026-11-10 08:00:00Z],
        layer_record_count: 3
      }

      result =
        run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z]),
          sources: two_sources([], answer: {:stale, stale})
        )

      assert result == {:ok, %{outcome: :stale}}
      assert stored_files(context.tmp_dir) == before
      assert Addresses.manifest(context.server) == {:ok, current}
    end

    test "a failed fetch of the second source is an error that names it and keeps the build",
         context do
      run(context, sources: two_sources())
      {:ok, current} = Addresses.manifest(context.server)

      result =
        run(context, sources: two_sources([], answer: {:error, {:transport, :timeout}}))

      assert result == {:error, {:fetch, :test_two, {:transport, :timeout}}}
      assert Addresses.manifest(context.server) == {:ok, current}
    end

    test "a count of records that differs from the second source's layer is an error that names it",
         context do
      result = run(context, sources: two_sources([], record_count: 4))

      assert result == {:error, {:record_count_differs, :test_two, 3, 4}}
      assert Addresses.manifest(context.server) == :none
    end

    test "deletes every export when the run ends", context do
      run(context, sources: two_sources())
      refute File.exists?(Path.join(context.tmp_dir, "work"))
    end
  end

  test "deletes the export when the run ends", context do
    run(context)
    refute File.exists?(Path.join(context.tmp_dir, "work"))
  end

  test "a process started over a stored build holds its manifest and when it was built",
       context do
    run(context)
    {:ok, manifest} = Addresses.manifest(context.server)

    restarted = Module.concat(__MODULE__, "Restarted#{context.line}")

    start_supervised!({Addresses, name: restarted, read_options: [base_dir: context.tmp_dir]},
      id: :restarted
    )

    assert Addresses.manifest(restarted) == {:ok, manifest}
    assert {:ok, %{built_on: ~D[2026-11-10], built_at: @now}} = Addresses.built(restarted)
    assert {:ok, %{inputs_sha256: sha256}} = Addresses.built(restarted)
    assert Base.encode16(sha256, case: :lower) == manifest["inputsSha256"]
  end

  test "a process over no stored build holds no manifest", context do
    assert Addresses.manifest(context.server) == :none
    assert Addresses.built(context.server) == :none
  end

  test "the newest of two stored builds is the one a start finds", context do
    run(context)
    run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z]))
    {:ok, newest} = Addresses.manifest(context.server)

    restarted = Module.concat(__MODULE__, "Restarted#{context.line}")

    start_supervised!({Addresses, name: restarted, read_options: [base_dir: context.tmp_dir]},
      id: :restarted
    )

    assert Addresses.manifest(restarted) == {:ok, newest}
    assert newest["builtAt"] == "2026-11-11T12:00:00Z"
  end
end
