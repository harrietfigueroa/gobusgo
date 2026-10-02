defmodule Gobusgo.ReaderTest do
  # Verifies backend selection and the result contract through Gobusgo.Reader
  # with in-memory backends, so no storage is touched. Application config
  # is global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.Reader

  defmodule RecordingBackend do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      send(Keyword.fetch!(options, :recipient), {:read, destination, options})
      {:ok, "content of " <> destination}
    end

    @impl Gobusgo.Reader
    def discover(request, options) do
      send(Keyword.fetch!(options, :recipient), {:discovered, request, options})
      {:ok, %{destinations: [request.prefix <> "a.json"], cursor: nil}}
    end
  end

  defmodule MissingBackend do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:error, :discovery_too_large}
  end

  # Answers with whatever the :answer option carries, so each off-contract
  # shape is one table row.
  defmodule ScriptedBackend do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, options), do: Keyword.fetch!(options, :answer)

    @impl Gobusgo.Reader
    def discover(_request, options), do: Keyword.fetch!(options, :answer)
  end

  # Caller code that knows only the generic interface; tests swap the backend
  # underneath it through options or config.
  defmodule Caller do
    def load(options), do: Reader.read("reports/latest.json", options)

    def inputs(options) do
      Reader.discover(%{prefix: "raw/", limit: 10, order: :ascending, cursor: nil}, options)
    end
  end

  defp discovery(overrides) do
    Map.merge(%{prefix: "raw/", limit: 2, order: :ascending, cursor: nil}, Map.new(overrides))
  end

  describe "read/2 with an injected backend" do
    test "passes the destination to the backend and returns its content" do
      assert Reader.read("a/b.json", backend: RecordingBackend, recipient: self()) ==
               {:ok, "content of a/b.json"}

      assert_received {:read, "a/b.json", _options}
    end

    test "passes backend options through and strips the backend key" do
      Reader.read("a", backend: RecordingBackend, recipient: self())

      assert_received {:read, _destination, options}
      assert options == [recipient: self()]
    end

    test "returns a documented error as a value" do
      assert Reader.read("a", backend: MissingBackend) == {:error, :not_found}
    end

    for {name, answer} <- [
          {"an error outside the contract", {:error, :enoent}},
          {"an invalid destination detail outside the contract",
           {:error, {:invalid_destination, :eloop}}},
          {"content that is not a binary", {:ok, :content}},
          {"a bare value", :ok}
        ] do
      test "raises when a backend returns #{name}" do
        assert_raise Gobusgo.Assert.AssertionError, fn ->
          Reader.read("a", backend: ScriptedBackend, answer: unquote(Macro.escape(answer)))
        end
      end
    end
  end

  describe "discover/2 with an injected backend" do
    test "passes the request to the backend and returns its page" do
      request = discovery([])

      assert Reader.discover(request, backend: RecordingBackend, recipient: self()) ==
               {:ok, %{destinations: ["raw/a.json"], cursor: nil}}

      assert_received {:discovered, ^request, [recipient: _recipient]}
    end

    test "returns a page whose cursor continues the listing" do
      page = %{destinations: ["raw/a", "raw/b"], cursor: "raw/b"}

      assert Reader.discover(discovery([]), backend: ScriptedBackend, answer: {:ok, page}) ==
               {:ok, page}
    end

    test "returns a documented error as a value" do
      assert Reader.discover(discovery([]), backend: MissingBackend) ==
               {:error, :discovery_too_large}
    end

    for {name, answer} <- [
          {"an error outside the contract", {:error, :eacces}},
          {"more destinations than the limit",
           {:ok, %{destinations: ["raw/a", "raw/b", "raw/c"], cursor: nil}}},
          {"a destination outside the prefix", {:ok, %{destinations: ["other/a"], cursor: nil}}},
          {"a cursor that is not a string", {:ok, %{destinations: ["raw/a"], cursor: 1}}},
          {"a cursor on an empty page", {:ok, %{destinations: [], cursor: "raw/a"}}},
          {"a page without a cursor key", {:ok, %{destinations: []}}},
          {"a bare list", {:ok, ["raw/a"]}}
        ] do
      test "raises when a backend returns #{name}" do
        assert_raise Gobusgo.Assert.AssertionError, fn ->
          Reader.discover(discovery([]),
            backend: ScriptedBackend,
            answer: unquote(Macro.escape(answer))
          )
        end
      end
    end

    for {name, overrides} <- [
          {"a zero limit", [limit: 0]},
          {"a limit above the maximum", [limit: 1001]},
          {"a fractional limit", [limit: 1.5]},
          {"an unknown order", [order: :random]}
        ] do
      test "raises for #{name} before reaching the backend" do
        assert_raise Gobusgo.Assert.AssertionError, fn ->
          Reader.discover(discovery(unquote(overrides)),
            backend: RecordingBackend,
            recipient: self()
          )
        end

        refute_received {:discovered, _request, _options}
      end
    end

    test "accepts the maximum limit" do
      request = discovery(limit: Reader.discovery_limit_max())

      assert {:ok, _page} = Reader.discover(request, backend: RecordingBackend, recipient: self())
    end
  end

  describe "backend selection from application config" do
    setup do
      previous = Application.fetch_env!(:gobusgo, Reader)
      on_exit(fn -> Application.put_env(:gobusgo, Reader, previous) end)
    end

    test "uses the configured backend when none is injected" do
      Application.put_env(:gobusgo, Reader, backend: MissingBackend)

      assert Caller.load([]) == {:error, :not_found}
    end

    test "lets an injected backend override the configured one" do
      Application.put_env(:gobusgo, Reader, backend: MissingBackend)

      assert Caller.load(backend: RecordingBackend, recipient: self()) ==
               {:ok, "content of reports/latest.json"}
    end

    test "runs the same reading caller against a different backend" do
      Application.put_env(:gobusgo, Reader, backend: RecordingBackend)

      assert Caller.load(recipient: self()) == {:ok, "content of reports/latest.json"}
      assert_received {:read, "reports/latest.json", _options}
    end

    test "runs the same discovering caller against a different backend" do
      Application.put_env(:gobusgo, Reader, backend: RecordingBackend)

      assert Caller.inputs(recipient: self()) ==
               {:ok, %{destinations: ["raw/a.json"], cursor: nil}}
    end
  end
end
