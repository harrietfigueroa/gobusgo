defmodule Gobusgo.UsageTest do
  # Starts a recorder per test with clocks the test moves and a file
  # backend under the test's temporary directory, registers connections
  # from processes the test starts and stops, and reads the files the
  # recorder writes back through the reader.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Reader
  alias Gobusgo.Usage

  @moduletag :tmp_dir

  @connected_at ~U[2026-10-08 17:00:00Z]
  @prefix "usage/page-connections/"
  @poll_ms 10
  @timer_wait_ms 5_000
  @connection %{
    page: "vehicle",
    reconnect: false,
    device_class: "desktop",
    browser_family: "firefox",
    viewport_width_bucket: "1024-1439",
    language: "en",
    referrer_host: nil
  }

  defmodule FailingWriter do
    @moduledoc false
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(_request, _options), do: {:error, :storage_full}
  end

  setup %{tmp_dir: tmp_dir} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    %{clock: clock, base_dir: tmp_dir}
  end

  defp start(context, options \\ []) do
    name = Module.concat(__MODULE__, "Recorder#{System.unique_integer([:positive])}")
    clock = context.clock

    options =
      Keyword.merge(
        [
          name: name,
          write_options: [base_dir: context.base_dir],
          write_interval_ms: 3_600_000,
          clock: fn -> @connected_at end,
          monotonic_time_ms: fn -> Agent.get(clock, & &1) end
        ],
        options
      )

    start_supervised!({Usage, options})
    name
  end

  defp advance(%{clock: clock}, ms), do: Agent.update(clock, &(&1 + ms))

  # A process that registers `connection`, answers `{:filter, filter}` by
  # naming the filter and `{:register_again, connection, test}` by
  # registering once more, and exits on `:stop`.
  defp connect(recorder, connection \\ @connection) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:registered, self(), Usage.register(recorder, connection)})
        page_loop(recorder)
      end)

    assert_receive {:registered, ^pid, result}
    {pid, result}
  end

  defp page_loop(recorder) do
    receive do
      {:filter, filter} ->
        :ok = Usage.put_filter(recorder, filter)
        page_loop(recorder)

      {:register_again, connection, test} ->
        send(test, {:registered_again, Usage.register(recorder, connection)})
        page_loop(recorder)

      :stop ->
        :ok
    end
  end

  defp stop(pid) do
    reference = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
  end

  defp files(%{base_dir: base_dir}) do
    {:ok, %{destinations: destinations, cursor: nil}} =
      Reader.discover(%{prefix: @prefix, limit: 100, order: :ascending, cursor: nil},
        base_dir: base_dir
      )

    for destination <- destinations do
      {:ok, content} = Reader.read(destination, base_dir: base_dir)
      JSON.decode!(content)
    end
  end

  # The files, read again every few milliseconds until there is one or
  # `wait_ms` have passed.
  defp await_files(context, wait_ms) do
    case files(context) do
      [] when wait_ms > 0 ->
        Process.sleep(@poll_ms)
        await_files(context, wait_ms - @poll_ms)

      files ->
        files
    end
  end

  describe "a connection that ends" do
    test "is written as one record with the time it was open", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      advance(context, 42_000)
      stop(pid)

      assert Usage.write(recorder) == {:ok, 1}

      assert [%{"meta" => %{"recordCount" => 1}, "records" => [record]}] = files(context)

      assert %{
               "page" => "vehicle",
               "durationMs" => 42_000,
               "connectedAt" => "2026-10-08T17:00:00Z",
               "deviceClass" => "desktop",
               "reconnect" => false
             } = record
    end

    test "is written once", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      stop(pid)

      assert Usage.write(recorder) == {:ok, 1}
      assert Usage.write(recorder) == {:ok, 0}
      assert length(files(context)) == 1
    end

    test "is recorded when its process crashes", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      reference = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}

      assert Usage.write(recorder) == {:ok, 1}
    end

    test "holds the last filter its page named", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      send(pid, {:filter, %{"agency" => ["1"]}})
      send(pid, {:filter, %{"agency" => ["40"], "route" => ["40_100479"]}})
      stop(pid)

      assert Usage.write(recorder) == {:ok, 1}

      assert [%{"records" => [%{"filter" => %{"agency" => ["40"], "route" => ["40_100479"]}}]}] =
               files(context)
    end
  end

  describe "a connection that is still open" do
    test "is not written", context do
      recorder = start(context)
      {_pid, :ok} = connect(recorder)

      assert Usage.write(recorder) == {:ok, 0}
      assert files(context) == []
    end
  end

  describe "write/1" do
    test "writes no file when no connection has ended", context do
      recorder = start(context)

      assert Usage.write(recorder) == {:ok, 0}
      assert files(context) == []
    end

    test "writes the connections that ended since the last file into a file of their own",
         context do
      recorder = start(context)
      {first, :ok} = connect(recorder)
      stop(first)
      assert Usage.write(recorder) == {:ok, 1}

      {second, :ok} = connect(recorder, %{@connection | page: "agency"})
      stop(second)
      assert Usage.write(recorder) == {:ok, 1}

      pages = for %{"records" => [%{"page" => page}]} <- files(context), do: page
      assert Enum.sort(pages) == ["agency", "vehicle"]
    end

    test "logs one summary line with the count written", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      stop(pid)

      log = capture_log([metadata: :all], fn -> Usage.write(recorder) end)

      assert log =~ "Usage records written"
      assert log =~ "record_count=1"
      assert log =~ "dropped_open_count=0"
      assert log =~ "dropped_closed_count=0"
    end

    test "keeps the records of a write that fails, and logs the failure", context do
      recorder = start(context, write_options: [backend: FailingWriter])
      {pid, :ok} = connect(recorder)
      stop(pid)

      log =
        capture_log([metadata: :all], fn ->
          assert Usage.write(recorder) == {:error, :storage_full}
          assert Usage.write(recorder) == {:error, :storage_full}
        end)

      assert log =~ "Usage records not written"
      assert log =~ "record_count=1"
    end
  end

  describe "the timer" do
    test "writes the records the recorder holds", context do
      recorder = start(context, write_interval_ms: 20)
      {pid, :ok} = connect(recorder)
      stop(pid)

      assert [%{"records" => [_record]}] = await_files(context, @timer_wait_ms)
    end
  end

  describe "a recorder that shuts down" do
    test "writes the records it holds", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      stop(pid)
      # A call the recorder answers after the exit of `pid` reached it.
      {_other, :ok} = connect(recorder)

      :ok = stop_supervised(Usage)

      assert [%{"records" => [_record]}] = files(context)
    end
  end

  describe "the bounds" do
    test "refuse a connection beyond the count of open ones", context do
      recorder = start(context, open_count_max: 1)
      {_first, :ok} = connect(recorder)

      assert {_second, {:error, :open_count_exceeded}} = connect(recorder)
    end

    test "drop the record of a connection beyond the count held, and report both counts",
         context do
      recorder = start(context, open_count_max: 2, closed_count_max: 1)
      {first, :ok} = connect(recorder)
      {second, :ok} = connect(recorder)
      {_third, {:error, :open_count_exceeded}} = connect(recorder)
      stop(first)
      stop(second)

      log =
        capture_log([metadata: :all], fn -> assert Usage.write(recorder) == {:ok, 1} end)

      assert log =~ "dropped_open_count=1"
      assert log =~ "dropped_closed_count=1"
    end

    test "report a dropped count once", context do
      recorder = start(context, open_count_max: 1)
      {first, :ok} = connect(recorder)
      {_refused, {:error, :open_count_exceeded}} = connect(recorder)
      stop(first)
      assert Usage.write(recorder) == {:ok, 1}

      {second, :ok} = connect(recorder)
      stop(second)
      log = capture_log([metadata: :all], fn -> Usage.write(recorder) end)

      assert log =~ "dropped_open_count=0"
    end
  end

  describe "register/2" do
    test "keeps the connection a process has already", context do
      recorder = start(context)
      {pid, :ok} = connect(recorder)
      advance(context, 1_000)
      send(pid, {:register_again, %{@connection | page: "agency"}, self()})
      assert_receive {:registered_again, :ok}
      advance(context, 1_000)
      stop(pid)

      assert Usage.write(recorder) == {:ok, 1}
      assert [%{"records" => [%{"page" => "vehicle", "durationMs" => 2_000}]}] = files(context)
    end

    test "answers that a recorder that is not running is unavailable" do
      assert Usage.register(Gobusgo.UsageTest.NoRecorder, @connection) == {:error, :unavailable}
    end
  end

  describe "count/2" do
    test "records a request as a connection that ended the moment it began", context do
      recorder = start(context)
      advance(context, 5_000)

      assert Usage.count(recorder, %{@connection | page: "mcp"}) == :ok
      advance(context, 5_000)

      assert Usage.write(recorder) == {:ok, 1}
      assert [%{"records" => [%{"page" => "mcp", "durationMs" => 0}]}] = files(context)
    end

    test "records each request of one process, which register/2 would keep as one", context do
      recorder = start(context)

      assert Usage.count(recorder, %{@connection | page: "mcp"}) == :ok
      assert Usage.count(recorder, %{@connection | page: "mcp"}) == :ok

      assert Usage.write(recorder) == {:ok, 2}
    end

    test "leaves no connection open, so the open bound still has room", context do
      recorder = start(context, open_count_max: 1)

      assert Usage.count(recorder, %{@connection | page: "mcp"}) == :ok
      assert Usage.count(recorder, %{@connection | page: "mcp"}) == :ok
      assert {_pid, :ok} = connect(recorder)
    end

    test "refuses a request while the open connections are at their bound", context do
      recorder = start(context, open_count_max: 1)
      {_pid, :ok} = connect(recorder)

      assert Usage.count(recorder, %{@connection | page: "mcp"}) ==
               {:error, :open_count_exceeded}
    end

    test "answers that a recorder that is not running is unavailable" do
      assert Usage.count(Gobusgo.UsageTest.NoRecorder, @connection) == {:error, :unavailable}
    end
  end

  describe "put_filter/2" do
    test "changes nothing for a recorder that is not running" do
      assert Usage.put_filter(Gobusgo.UsageTest.NoRecorder, %{"agency" => ["1"]}) == :ok
    end
  end
end
