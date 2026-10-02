defmodule Gobusgo.WriterTest do
  # Verifies backend selection and the result contract through Gobusgo.Writer
  # with in-memory backends, so no filesystem is touched. Application config
  # is global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.Writer

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:written, request, options})
      :ok
    end
  end

  defmodule RefusingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(_request, _options), do: {:error, :already_exists}
  end

  defmodule OffContractBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(_request, _options), do: {:error, :enoent}
  end

  # Caller code that knows only the generic interface; tests swap the backend
  # underneath it through options or config.
  defmodule Caller do
    def save(content, options) do
      Writer.write(%{destination: "reports/latest.json", content: content}, options)
    end
  end

  describe "write/2 with an injected backend" do
    test "passes the request to the backend and returns its ok result" do
      request = %{destination: "a/b.json", content: "payload"}

      assert Writer.write(request, backend: RecordingBackend, recipient: self()) == :ok
      assert_received {:written, ^request, _options}
    end

    test "passes backend options through and strips the backend key" do
      Writer.write(%{destination: "a", content: ""}, backend: RecordingBackend, recipient: self())

      assert_received {:written, _request, options}
      assert options == [recipient: self()]
    end

    test "returns a documented error as a value" do
      request = %{destination: "a", content: "x"}

      assert Writer.write(request, backend: RefusingBackend) == {:error, :already_exists}
    end

    test "raises when a backend returns an error outside the contract" do
      request = %{destination: "a", content: "x"}

      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Writer.write(request, backend: OffContractBackend)
      end
    end
  end

  describe "backend selection from application config" do
    setup do
      previous = Application.fetch_env!(:gobusgo, Writer)
      on_exit(fn -> Application.put_env(:gobusgo, Writer, previous) end)
    end

    test "uses the configured backend when none is injected" do
      Application.put_env(:gobusgo, Writer, backend: RefusingBackend)

      assert Caller.save("x", []) == {:error, :already_exists}
    end

    test "lets an injected backend override the configured one" do
      Application.put_env(:gobusgo, Writer, backend: RefusingBackend)

      assert Caller.save("x", backend: RecordingBackend, recipient: self()) == :ok
    end

    test "runs the same caller code against a different backend" do
      Application.put_env(:gobusgo, Writer, backend: RecordingBackend)

      assert Caller.save("body", recipient: self()) == :ok
      assert_received {:written, %{destination: "reports/latest.json", content: "body"}, _}
    end
  end
end
