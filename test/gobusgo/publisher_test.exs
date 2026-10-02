defmodule Gobusgo.PublisherTest do
  # Verifies backend selection and the result contract through
  # Gobusgo.Publisher with in-memory backends, so nothing is published.
  # Application config is global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Publisher

  defmodule RecordingBackend do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records, options})
      :ok
    end
  end

  defmodule RefusingBackend do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, _options), do: {:error, :timeout}
  end

  defmodule OffContractBackend do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, _options), do: {:error, :leader_not_available}
  end

  @record %{topic: "sample.topic", key: "sample/1", value: "payload", headers: [{"a", "b"}]}

  describe "publish/2 with an injected backend" do
    test "passes the records to the backend and returns its ok result" do
      records = [@record, %{@record | key: "sample/2"}]

      assert Publisher.publish(records, backend: RecordingBackend, recipient: self()) == :ok
      assert_received {:published, ^records, _options}
    end

    test "passes backend options through and strips the backend key" do
      Publisher.publish([@record], backend: RecordingBackend, recipient: self())

      assert_received {:published, _records, options}
      assert options == [recipient: self()]
    end

    test "returns a documented error as a value" do
      assert Publisher.publish([@record], backend: RefusingBackend) == {:error, :timeout}
    end

    test "raises when a backend returns an error outside the contract" do
      assert_raise AssertionError, ~r/undocumented/, fn ->
        Publisher.publish([@record], backend: OffContractBackend)
      end
    end
  end

  describe "publish/2 assertions" do
    test "raises for an empty list of records" do
      assert_raise AssertionError, ~r/at least 1/, fn ->
        Publisher.publish([], backend: RecordingBackend, recipient: self())
      end
    end

    test "raises for more records than the bound" do
      records = List.duplicate(@record, Publisher.record_count_max() + 1)

      assert_raise AssertionError, ~r/at most/, fn ->
        Publisher.publish(records, backend: RecordingBackend, recipient: self())
      end

      refute_received {:published, _records, _options}
    end

    for {description, change, pattern} <- [
          {"an empty topic", %{topic: ""}, ~r/topic/},
          {"a key that is not a string", %{key: 1}, ~r/key/},
          {"a value that is not a binary", %{value: %{}}, ~r/value/},
          {"a header that is not a pair of strings", %{headers: [{"a", 1}]}, ~r/headers/}
        ] do
      test "raises for #{description}" do
        record = Map.merge(@record, unquote(Macro.escape(change)))

        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          Publisher.publish([record], backend: RecordingBackend, recipient: self())
        end
      end
    end
  end

  describe "backend selection from application config" do
    setup do
      previous = Application.fetch_env(:gobusgo, Publisher)

      on_exit(fn ->
        case previous do
          {:ok, config} -> Application.put_env(:gobusgo, Publisher, config)
          :error -> Application.delete_env(:gobusgo, Publisher)
        end
      end)
    end

    test "uses the configured backend when none is injected" do
      Application.put_env(:gobusgo, Publisher, backend: RefusingBackend)

      assert Publisher.publish([@record], []) == {:error, :timeout}
    end

    test "lets an injected backend override the configured one" do
      Application.put_env(:gobusgo, Publisher, backend: RefusingBackend)

      assert Publisher.publish([@record], backend: RecordingBackend, recipient: self()) == :ok
    end

    test "raises when no backend is configured or injected" do
      Application.delete_env(:gobusgo, Publisher)

      assert_raise AssertionError, ~r/no backend/, fn -> Publisher.publish([@record], []) end
    end
  end
end
