defmodule Gobusgo.CleanupTest do
  # Runs the cleanup over content the test writes under its temporary
  # directory through the file backends, on a date the test names, and reads
  # what is left. A backend that fails stands in for storage that does.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Cleanup
  alias Gobusgo.Deleter
  alias Gobusgo.Reader
  alias Gobusgo.Writer

  @moduletag :tmp_dir

  @today ~D[2026-10-08]
  @vehicles %{prefix: "raw/oba/vehicles-for-agency", day_count: 1}
  @usage %{prefix: "usage/page-connections", day_count: 3}

  defmodule FailingDeleter do
    @moduledoc false
    @behaviour Gobusgo.Deleter

    @impl Gobusgo.Deleter
    def delete(%{destination: destination} = request, options) do
      case String.contains?(destination, "stuck") do
        true -> {:error, :permission_denied}
        false -> Gobusgo.Deleter.LocalFile.delete(request, options)
      end
    end
  end

  defmodule FailingReader do
    @moduledoc false
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :io_failure}

    @impl Gobusgo.Reader
    def discover(%{prefix: prefix} = request, options) do
      case String.starts_with?(prefix, Keyword.fetch!(options, :failing_prefix)) do
        true -> {:error, :io_failure}
        false -> Gobusgo.Reader.LocalFile.discover(request, options)
      end
    end
  end

  defp write(%{tmp_dir: base_dir}, destinations) do
    for destination <- destinations do
      :ok =
        Writer.write(%{destination: destination, content: "content"},
          backend: Writer.LocalFile,
          base_dir: base_dir
        )
    end
  end

  defp run(%{tmp_dir: base_dir}, rules, options \\ []) do
    {delete_options, options} = Keyword.pop(options, :delete_options, backend: Deleter.LocalFile)
    {read_options, options} = Keyword.pop(options, :read_options, backend: Reader.LocalFile)

    Cleanup.run(
      rules,
      Keyword.merge(
        [
          today: @today,
          read_options: Keyword.put(read_options, :base_dir, base_dir),
          delete_options: Keyword.put(delete_options, :base_dir, base_dir)
        ],
        options
      )
    )
  end

  defp left(%{tmp_dir: base_dir}, prefix) do
    {:ok, %{destinations: destinations, cursor: nil}} =
      Reader.discover(%{prefix: prefix, limit: 1_000, order: :ascending, cursor: nil},
        backend: Reader.LocalFile,
        base_dir: base_dir
      )

    destinations
  end

  defp vehicle(date, name), do: "raw/oba/vehicles-for-agency/dt=#{date}/agency=1/#{name}.json.gz"
  defp usage(date, name), do: "usage/page-connections/dt=#{date}/#{name}.json.gz"

  describe "run/2" do
    test "deletes content past its retention and keeps newer content", context do
      write(context, [
        vehicle("2026-10-05", "a"),
        vehicle("2026-10-06", "b"),
        vehicle("2026-10-07", "c"),
        vehicle("2026-10-08", "d")
      ])

      assert {:ok, %{deleted_count: 2, failed_count: 0, backlog: false}} =
               run(context, [@vehicles])

      assert left(context, "raw/") == [vehicle("2026-10-07", "c"), vehicle("2026-10-08", "d")]
    end

    test "judges each dataset by its own rule", context do
      write(context, [
        vehicle("2026-10-05", "a"),
        usage("2026-10-04", "b"),
        usage("2026-10-05", "c")
      ])

      assert {:ok, %{deleted_count: 2}} = run(context, [@vehicles, @usage])

      assert left(context, "raw/") == []
      assert left(context, "usage/") == [usage("2026-10-05", "c")]
    end

    test "deletes nothing when nothing is past its retention", context do
      write(context, [vehicle("2026-10-07", "a")])

      assert run(context, [@vehicles]) ==
               {:ok,
                %{
                  deleted_count: 0,
                  failed_count: 0,
                  unrecognized_count: 0,
                  discovery_failed_count: 0,
                  backlog: false
                }}
    end

    test "finishes for a dataset that holds nothing", context do
      assert {:ok, %{deleted_count: 0, backlog: false}} = run(context, [@vehicles])
    end

    test "leaves content of another dataset alone, however old", context do
      old = "raw/oba/routes-for-agency/dt=2026-01-01/agency=1/a.json.gz"
      write(context, [old])

      assert {:ok, %{deleted_count: 0}} = run(context, [@vehicles])
      assert left(context, "raw/") == [old]
    end

    test "counts a day that is no date, and deletes the content after it", context do
      strange = "raw/oba/vehicles-for-agency/dt=2026-1-1/agency=1/a.json.gz"
      write(context, [strange, vehicle("2026-10-05", "b")])

      assert {:ok, %{deleted_count: 1, unrecognized_count: 1}} = run(context, [@vehicles])
      assert left(context, "raw/") == [strange]
    end

    test "deletes more content than one page of destinations holds", context do
      write(context, for(index <- 1..1_005, do: vehicle("2026-10-05", "f#{index}")))

      assert {:ok, %{deleted_count: 1_005, backlog: false}} = run(context, [@vehicles])
      assert left(context, "raw/") == []
    end
  end

  describe "the bound of one run" do
    test "deletes at most the count it is given, the oldest content first", context do
      write(context, [
        vehicle("2026-10-03", "a"),
        vehicle("2026-10-04", "b"),
        vehicle("2026-10-05", "c")
      ])

      assert {:ok, %{deleted_count: 2, backlog: true}} =
               run(context, [@vehicles], delete_count_max: 2)

      assert left(context, "raw/") == [vehicle("2026-10-05", "c")]
    end

    test "reports no backlog when the count is used up and nothing expired is left", context do
      write(context, [vehicle("2026-10-05", "a"), vehicle("2026-10-07", "b")])

      assert {:ok, %{deleted_count: 1, backlog: false}} =
               run(context, [@vehicles], delete_count_max: 1)
    end

    test "reports the backlog of a dataset it did not reach", context do
      write(context, [vehicle("2026-10-05", "a"), usage("2026-10-01", "b")])

      assert {:ok, %{deleted_count: 1, backlog: true}} =
               run(context, [@vehicles, @usage], delete_count_max: 1)

      assert left(context, "usage/") == [usage("2026-10-01", "b")]
    end

    test "deletes the rest in the next run", context do
      write(context, [vehicle("2026-10-04", "a"), vehicle("2026-10-05", "b")])
      {:ok, %{backlog: true}} = run(context, [@vehicles], delete_count_max: 1)

      assert {:ok, %{deleted_count: 1, backlog: false}} =
               run(context, [@vehicles], delete_count_max: 1)

      assert left(context, "raw/") == []
    end
  end

  describe "a deletion that fails" do
    test "is counted, and the run deletes the rest", context do
      write(context, [
        vehicle("2026-10-04", "a"),
        vehicle("2026-10-04", "stuck"),
        vehicle("2026-10-05", "c")
      ])

      assert {:ok, %{deleted_count: 2, failed_count: 1}} =
               run(context, [@vehicles], delete_options: [backend: FailingDeleter])

      assert left(context, "raw/") == [vehicle("2026-10-04", "stuck")]
    end

    test "counts toward the bound, so content that never deletes cannot hold a run", context do
      write(context, [vehicle("2026-10-04", "stuck"), vehicle("2026-10-05", "b")])

      assert {:ok, %{deleted_count: 0, failed_count: 1, backlog: true}} =
               run(context, [@vehicles],
                 delete_options: [backend: FailingDeleter],
                 delete_count_max: 1
               )
    end

    test "is logged as a degraded run, once", context do
      write(context, [vehicle("2026-10-04", "stuck")])

      log =
        capture_log([metadata: :all], fn ->
          run(context, [@vehicles], delete_options: [backend: FailingDeleter])
        end)

      assert log =~ "[warning] Stored content cleanup finished degraded"
      assert log =~ "failed_count=1"
    end
  end

  describe "a discovery that fails" do
    test "is counted, and the run cleans the other datasets", context do
      write(context, [vehicle("2026-10-05", "a"), usage("2026-10-01", "b")])

      assert {:ok, %{deleted_count: 1, discovery_failed_count: 1}} =
               run(context, [@vehicles, @usage],
                 read_options: [backend: FailingReader, failing_prefix: "raw/"]
               )

      assert left(context, "raw/") == [vehicle("2026-10-05", "a")]
      assert left(context, "usage/") == []
    end

    test "of every dataset fails the run, logged as an error", context do
      log =
        capture_log([metadata: :all], fn ->
          assert run(context, [@vehicles, @usage],
                   read_options: [backend: FailingReader, failing_prefix: ""]
                 ) == {:error, :nothing_examined}
        end)

      assert log =~ "[error] Stored content cleanup failed"
      assert log =~ "discovery_failed_count=2"
    end
  end

  describe "the summary line" do
    test "is logged at info with the counts of the run", context do
      write(context, [vehicle("2026-10-05", "a")])

      log = capture_log([metadata: :all], fn -> run(context, [@vehicles]) end)

      assert log =~ "[info] Stored content cleanup finished"
      assert log =~ "deleted_count=1"
      assert log =~ "failed_count=0"
      assert log =~ "backlog=false"
    end
  end
end
