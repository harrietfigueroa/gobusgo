defmodule Gobusgo.DeleterTest do
  # Verifies backend selection and the result contract through
  # Gobusgo.Deleter with in-memory backends, so no storage is touched.
  # Application config is global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Deleter

  @request %{destination: "a/b/c.json", within: "a/"}

  defmodule RecordingBackend do
    @behaviour Gobusgo.Deleter

    @impl Gobusgo.Deleter
    def delete(request, options) do
      send(Keyword.fetch!(options, :recipient), {:deleted, request, options})
      :ok
    end
  end

  defmodule AnsweringBackend do
    @behaviour Gobusgo.Deleter

    @impl Gobusgo.Deleter
    def delete(_request, options), do: Keyword.fetch!(options, :answer)
  end

  describe "delete/2 with an injected backend" do
    test "passes the request to the backend and returns its ok result" do
      assert Deleter.delete(@request, backend: RecordingBackend, recipient: self()) == :ok
      assert_received {:deleted, @request, _options}
    end

    test "passes backend options through and strips the backend key" do
      Deleter.delete(@request, backend: RecordingBackend, recipient: self(), extra: 1)

      assert_received {:deleted, _request, options}
      assert options[:extra] == 1
      refute Keyword.has_key?(options, :backend)
    end

    for reason <- [
          :not_found,
          :permission_denied,
          :read_only,
          :io_failure,
          :destination_conflict,
          {:invalid_destination, :traversal},
          {:invalid_destination, :redirected}
        ] do
      test "returns the documented error #{inspect(reason)} as a value" do
        answer = {:error, unquote(Macro.escape(reason))}

        assert Deleter.delete(@request, backend: AnsweringBackend, answer: answer) == answer
      end
    end

    for answer <- [
          {:error, :enoent},
          {:error, {:invalid_destination, :unheard_of}},
          :deleted,
          nil
        ] do
      test "raises for the off-contract answer #{inspect(answer)}" do
        assert_raise AssertionError, fn ->
          Deleter.delete(@request,
            backend: AnsweringBackend,
            answer: unquote(Macro.escape(answer))
          )
        end
      end
    end
  end

  describe "delete/2 with a within that is no such prefix" do
    for {label, request} <- [
          {"a within that does not end in /", %{destination: "a/b/c.json", within: "a"}},
          {"a within the destination does not start with",
           %{destination: "a/b/c.json", within: "x/"}},
          {"a within that is the whole destination", %{destination: "a/b/", within: "a/b/"}}
        ] do
      test "raises for #{label}, and asks the backend for nothing" do
        assert_raise AssertionError, fn ->
          Deleter.delete(unquote(Macro.escape(request)),
            backend: RecordingBackend,
            recipient: self()
          )
        end

        refute_received {:deleted, _request, _options}
      end
    end
  end

  describe "delete/2 with the configured backend" do
    setup do
      configured = Application.fetch_env!(:gobusgo, Deleter)
      on_exit(fn -> Application.put_env(:gobusgo, Deleter, configured) end)
    end

    test "uses the backend the application config names" do
      Application.put_env(:gobusgo, Deleter, backend: AnsweringBackend)

      assert Deleter.delete(@request, answer: {:error, :not_found}) == {:error, :not_found}
    end
  end
end
