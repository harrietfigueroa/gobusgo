defmodule Gobusgo.Routing.SnapshotsWalkLinksTest do
  # Drives the walking links of a Snapshots process against the walk graph
  # fixture published into the test's temporary directory: the table it
  # answers once measured, the graph that is corrupt, the read that fails,
  # the process that outgrows its heap or its time. The measuring is
  # asynchronous, so a test asks until the answer settles.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Compression
  alias Gobusgo.Reader
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Routing.WalkLinks.Store
  alias Gobusgo.Test.WalkGraphFixture
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @units 100_000
  @settle_attempts_max 200
  @settle_pause_ms 25
  @heap_words 40_000_000
  @deadline_ms 60_000

  defmodule SlowReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      Process.sleep(Keyword.fetch!(options, :pause_ms))
      Gobusgo.Reader.LocalFile.read(destination, options)
    end

    @impl Gobusgo.Reader
    def discover(request, options), do: Gobusgo.Reader.LocalFile.discover(request, options)
  end

  defmodule FailingReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      if String.contains?(destination, "walk-graph-index") do
        {:error, :io_failure}
      else
        Gobusgo.Reader.LocalFile.read(destination, options)
      end
    end

    @impl Gobusgo.Reader
    def discover(request, options), do: Gobusgo.Reader.LocalFile.discover(request, options)
  end

  setup context do
    server = Module.concat(__MODULE__, "Server#{context.line}")
    start_supervised!({Snapshots, name: server})
    read_options = [backend: Reader.LocalFile, base_dir: context.tmp_dir]

    :ok =
      publish(%{
        built_at: ~U[2026-11-14 12:00:00Z],
        source_date: "2026-11-08T21:21:00Z",
        tiles: %{
          {4761, -8156} => packed(WalkGraphFixture.pieces(:west)),
          {4761, -8155} => packed(WalkGraphFixture.pieces(:east))
        },
        write_options: [backend: Writer.LocalFile, base_dir: context.tmp_dir],
        read_options: read_options
      })

    {:ok, manifest} = Store.manifest(read_options)
    %{server: server, manifest: manifest, read_options: read_options, tmp_dir: context.tmp_dir}
  end

  defp publish(%{write_options: write_options, read_options: read_options} = request) do
    options = [
      write_options: write_options,
      read_options: read_options,
      delete_options: [backend: Gobusgo.Deleter.LocalFile, base_dir: write_options[:base_dir]]
    ]

    {:ok, _published} =
      Publication.publish(Map.take(request, [:built_at, :source_date, :tiles]), options)

    :ok
  end

  defp packed(pieces) do
    for %{class: class, points: points} <- pieces do
      {class, for({lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>)}
    end
  end

  defp positions do
    %{
      "a" => %{lat: 4_761_450 / @units, lon: -12_233_600 / @units},
      "b" => %{lat: 4_761_450 / @units, lon: -12_233_400 / @units}
    }
  end

  defp request(context, overrides \\ %{}) do
    Map.merge(
      %{
        manifest: context.manifest,
        positions: positions(),
        read_options: context.read_options,
        heap_words_max: @heap_words,
        deadline_ms: @deadline_ms
      },
      overrides
    )
  end

  # Asks until the answer is neither pending nor absent, or fails the test.
  defp settled(context, overrides \\ %{}) do
    Enum.reduce_while(1..@settle_attempts_max, :pending, fn _attempt, _answer ->
      case Snapshots.walk_links(context.server, request(context, overrides)) do
        :pending ->
          Process.sleep(@settle_pause_ms)
          {:cont, :pending}

        answer ->
          {:halt, answer}
      end
    end)
  end

  test "answers pending while it measures, then the table as one binary", context do
    assert :pending = Snapshots.walk_links(context.server, request(context))
    assert {:ready, %{table: table, build_id: build_id}} = settled(context)

    assert is_binary(table)
    assert build_id == context.manifest.build_id
    assert %{stops: %{"a" => %{links: [{"b", _meters}]}}} = WalkLinks.unpack(table)
  end

  test "answers that a table is not current, and measures nothing, for a request that only asks",
       context do
    only_asking = request(context, %{start?: false})

    assert :not_current = Snapshots.walk_links(context.server, only_asking)
    assert :not_current = Snapshots.walk_links(context.server, only_asking)
    assert :pending = Snapshots.walk_links(context.server, request(context))
  end

  test "answers the table at once for positions it already holds", context do
    {:ready, _held} = settled(context)

    assert {:ready, %{table: _table}} = Snapshots.walk_links(context.server, request(context))
  end

  test "measures again for new positions, keeping what the old table held", context do
    {:ready, %{table: before_table}} = settled(context)
    added = Map.put(positions(), "c", %{lat: 4_761_300 / @units, lon: -12_233_600 / @units})

    assert :pending = Snapshots.walk_links(context.server, request(context, %{positions: added}))
    assert {:ready, %{table: after_table}} = settled(context, %{positions: added})

    assert before_table != after_table
    assert map_size(WalkLinks.unpack(after_table).stops) == 3
  end

  test "answers a corrupt graph as failed and does not read it again", context do
    shard =
      Path.join(
        context.tmp_dir,
        "intersections/walk-graph-#{context.manifest.build_id}-4761_-8156.bin.gz"
      )

    File.write!(shard, Compression.compress("not a shard"))

    log = capture_log(fn -> assert {:failed, :corrupt} = settled(context) end)
    assert log =~ "Routing walk graph corrupt"

    File.write!(shard, "")

    assert {:failed, :corrupt} = Snapshots.walk_links(context.server, request(context))
  end

  test "asks again after a read that failed, and says so at warning", context do
    options = [backend: FailingReader, base_dir: context.tmp_dir]

    log =
      capture_log([level: :warning], fn ->
        assert :pending =
                 Snapshots.walk_links(context.server, request(context, %{read_options: options}))

        Process.sleep(200)

        assert :pending =
                 Snapshots.walk_links(context.server, request(context, %{read_options: options}))
      end)

    assert log =~ "Routing walk links not built"
  end

  test "answers positions whose process outgrew its heap as killed, at error", context do
    log =
      capture_log(fn ->
        assert {:failed, :killed} = settled(context, %{heap_words_max: 1_000})
      end)

    assert log =~ "Routing walk links build killed"
  end

  test "asks again after the kill of a read that outlasted the deadline, at warning", context do
    options = [backend: SlowReader, base_dir: context.tmp_dir, pause_ms: 2_000]
    request = request(context, %{read_options: options, deadline_ms: 10, deadline_grace_ms: 50})

    log =
      capture_log([level: :warning], fn ->
        assert :pending = Snapshots.walk_links(context.server, request)
        Process.sleep(400)
      end)

    assert log =~ "Routing walk links not built"
    refute log =~ "Routing walk links build killed"
    assert :pending = Snapshots.walk_links(context.server, request)
  end

  test "answers a computation past its deadline as pending again, at warning", context do
    options = [backend: SlowReader, base_dir: context.tmp_dir, pause_ms: 40]

    log =
      capture_log([level: :warning], fn ->
        assert :pending =
                 Snapshots.walk_links(
                   context.server,
                   request(context, %{read_options: options, deadline_ms: 10})
                 )

        Process.sleep(300)
      end)

    assert log =~ "Routing walk links not built"
  end
end
