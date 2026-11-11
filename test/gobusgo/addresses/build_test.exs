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
          source: AddressSource,
          source_options: [records: Map.get(context, :records, records())],
          bounds: {:bounds, @bounds},
          clock: fn -> Map.get(context, :now, @now) end,
          write_options: [base_dir: tmp_dir]
        ],
        overrides
      )

    Build.run(options)
  end

  # The one county's entry of the combined manifest, and its build.
  defp manifest(server) do
    case Addresses.manifest(server) do
      {:ok, %{"counties" => [county]}} -> {:ok, county}
      :none -> :none
    end
  end

  defp built(server), do: Addresses.built(server, :test)

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

    assert {:ok, manifest} = manifest(context.server)
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
    {:ok, manifest} = manifest(context.server)

    index_stream =
      File.read!(Path.join(tmp_dir, String.trim_leading(manifest["index"]["path"], "/")))

    {:ok, index_content} = Packed.expand(index_stream, Format.expanded_bytes_max(:index))
    assert {:ok, %{entries: entries}} = Format.decode_index(index_content)
    assert Enum.map(entries, & &1.sha256) == Enum.map(manifest["shards"], & &1["sha256"])
    assert Enum.map(entries, & &1.byte_size) == Enum.map(manifest["shards"], & &1["byteSize"])

    decoded =
      for entry <- entries do
        name = Packed.file_name(%{kind: Format.shard_kind(), sha256: entry.sha256})
        stream = File.read!(Path.join([tmp_dir, "addresses/dt=2026-11-10", name]))
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
    {:ok, manifest} = manifest(context.server)

    for %{"path" => path, "sha256" => sha256} <- [manifest["index"] | manifest["shards"]] do
      assert path =~ ~r{/(addresses|addresses-index)-#{sha256}\.bin\.gz\z}
      assert File.exists?(Path.join(tmp_dir, String.trim_leading(path, "/")))
    end
  end

  test "leaves out the addresses outside the bounds and says how many", context do
    run(context)
    assert {:ok, %{"addressCount" => 4}} = manifest(context.server)
  end

  test "keeps every address with no bounds", context do
    assert {:ok, _outcome} = run(context, bounds: :none)
    assert {:ok, %{"addressCount" => 5}} = manifest(context.server)
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
    assert {:ok, %{built_on: ~D[2026-11-11]}} = built(context.server)
  end

  test "a changed address gives other names and a new manifest", context do
    run(context)
    {:ok, first} = manifest(context.server)
    changed = List.replace_at(records(), 0, record(house_number: "85", lat: 47.61))

    assert run(Map.put(context, :records, changed)) == {:ok, %{outcome: :built}}
    {:ok, second} = manifest(context.server)

    refute second["inputsSha256"] == first["inputsSha256"]
    refute second["shards"] == first["shards"]
  end

  test "reads the records of every page", context do
    pages = [
      {:records, Enum.take(records(), 2), 1},
      {:records, Enum.drop(records(), 2), 2}
    ]

    assert run(context, source_options: [records: records(), pages: pages]) ==
             {:ok, %{outcome: :built}}

    assert {:ok, %{"addressCount" => 4}} = manifest(context.server)
  end

  test "a page that failed is an error with its reason and writes nothing", context do
    failure = {:page, 100, {:unexpected_status, 403}}
    pages = [{:records, Enum.take(records(), 2), 1}, {:failed, failure}]

    result = run(context, source_options: [records: records(), pages: pages])

    assert result == {:error, {:fetch, :test, failure}}
    assert stored_files(context.tmp_dir) == []
    assert manifest(context.server) == :none
  end

  test "a failed run's log line carries its reason in the message", context do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        run(context, source_options: [answer: {:error, {:transport, :nxdomain}}])
      end)

    assert log =~ "Address shards not built: {:fetch, :test, {:transport, :nxdomain}}"
  end

  test "a failed fetch is an error and keeps the current build", context do
    run(context)
    {:ok, current} = manifest(context.server)

    result = run(context, source_options: [answer: {:error, {:transport, :timeout}}])

    assert result == {:error, {:fetch, :test, {:transport, :timeout}}}
    assert manifest(context.server) == {:ok, current}
  end

  test "records fewer than the layer's count are an error and write nothing", context do
    result = run(context, source_options: [records: records(), record_count: 6])

    assert result == {:error, {:record_count_differs, :test, 5, 6}}
    assert stored_files(context.tmp_dir) == []
    assert manifest(context.server) == :none
  end

  describe "one county" do
    test "the manifest names the county with its layer's last edit and record count", context do
      run(context)

      {:ok, manifest} = manifest(context.server)
      assert manifest["county"] == "test"
      assert manifest["sourceLastEditAt"] == "2026-11-09T12:00:00Z"
      assert manifest["recordCount"] == 5
    end

    test "the manifest is stored under a name that holds the county", context do
      run(context)

      assert [manifest_file] =
               context.tmp_dir |> stored_files() |> Enum.filter(&(&1 =~ "/manifest-"))

      assert manifest_file =~ ~r{^addresses/dt=2026-11-10/manifest-test-20261110T}
    end

    test "a run past the county's deadline is ended, named, with nothing written", context do
      slow = Stream.map([{:records, records(), 1}], fn page -> Process.sleep(500) && page end)
      options = [source_options: [records: records(), pages: slow], deadline_ms: 50]

      assert run(context, options) == {:error, {:deadline_exceeded, :test, 50}}
      assert stored_files(context.tmp_dir) == []
      assert manifest(context.server) == :none
    end
  end

  test "a failed write is an error and records no manifest", context do
    result = run(context, write_options: [backend: FailingBackend])

    assert result == {:error, {:write, :io_failure}}
    assert manifest(context.server) == :none
  end

  test "a build that outgrows its heap cap is killed and records no manifest", context do
    assert run(context, heap_words_max: 2_000) == {:error, :killed}
    assert manifest(context.server) == :none
    assert stored_files(context.tmp_dir) == []
  end

  test "the heap cap counts the binaries a process references" do
    bytes_over_cap = 4_000_000

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          held = :binary.copy(<<0>>, bytes_over_cap)
          :erlang.garbage_collect()
          # Keeps the binary referenced until the collection above has judged it.
          Process.sleep(byte_size(held))
        end,
        [:monitor, max_heap_size: Build.heap_cap(100_000)]
      )

    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end

  test "a process started over a stored build holds its manifest and when it was built",
       context do
    run(context)
    {:ok, manifest} = manifest(context.server)

    restarted = Module.concat(__MODULE__, "Restarted#{context.line}")

    start_supervised!({Addresses, name: restarted, read_options: [base_dir: context.tmp_dir]},
      id: :restarted
    )

    assert manifest(restarted) == {:ok, manifest}
    assert {:ok, %{built_on: ~D[2026-11-10], built_at: @now}} = built(restarted)
    assert {:ok, %{inputs_sha256: sha256}} = built(restarted)
    assert Base.encode16(sha256, case: :lower) == manifest["inputsSha256"]
  end

  test "a process over no stored build holds no manifest", context do
    assert manifest(context.server) == :none
    assert built(context.server) == :none
  end

  test "the newest of two stored builds is the one a start finds", context do
    run(context)
    run(Map.put(context, :now, ~U[2026-11-11 12:00:00Z]))
    {:ok, newest} = manifest(context.server)

    restarted = Module.concat(__MODULE__, "Restarted#{context.line}")

    start_supervised!({Addresses, name: restarted, read_options: [base_dir: context.tmp_dir]},
      id: :restarted
    )

    assert manifest(restarted) == {:ok, newest}
    assert newest["builtAt"] == "2026-11-11T12:00:00Z"
  end
end
