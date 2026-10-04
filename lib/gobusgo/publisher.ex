defmodule Gobusgo.Publisher do
  @record_count_max 1000

  @moduledoc """
  A backend-neutral contract for publishing records to topics, and the entry
  point that selects the backend.

  Callers use `publish/2` and name no backend. A record is a `:value`
  published to a `:topic` under a `:key`, with `:headers` that describe the
  value. Records published to one topic under one key keep their order.

  ## Contract

  `publish/2` takes between 1 and #{@record_count_max} records and returns
  once the outcome of every record is known:

    * `:ok` — every record is acknowledged as stored.
    * `{:error, reason}` — at least one record is not acknowledged; `reason`
      is one of `t:error_reason/0`. Other records of the call may be stored,
      so a caller that publishes again publishes some records twice.

  Operating errors return as values. Anything outside the documented set
  (a failure the backend cannot classify, a backend answering off-contract)
  raises `Gobusgo.Assert.AssertionError`.

  ## Tombstones

  A record whose `:value` is empty is a tombstone: it removes the earlier
  records of its key from the topic, and a reader of the topic receives no
  value for it. A later record under the same key supersedes the tombstone.

  ## Selecting a backend

  The application config key `:backend` under `Gobusgo.Publisher` names the
  default backend module. The `:backend` option of `publish/2` overrides it
  per call. Every other option goes to the backend untouched.
  """

  alias Gobusgo.Assert

  @type header :: {String.t(), String.t()}

  @type topic_record :: %{
          topic: String.t(),
          key: String.t(),
          value: binary(),
          headers: [header()]
        }

  @typedoc """
    * `:timeout` — no acknowledgement arrived within the backend's deadline.
    * `:unavailable` — the backend could not reach what stores the topic.
    * `:unknown_topic` — the topic does not exist.
    * `:record_too_large` — a record exceeds the backend's size limit.
  """
  @type error_reason :: :timeout | :unavailable | :unknown_topic | :record_too_large

  @type result :: :ok | {:error, error_reason()}

  @error_reasons [:timeout, :unavailable, :unknown_topic, :record_too_large]

  @doc """
  Publishes `records` in order and returns once every record is acknowledged
  or one is not. `options` is backend-specific; see each backend's
  documentation.
  """
  @callback publish(records :: [topic_record(), ...], options :: keyword()) :: result()

  @doc "Records allowed in one call."
  @spec record_count_max() :: pos_integer()
  def record_count_max, do: @record_count_max

  @doc """
  Publishes through the backend named by the `:backend` option, or by the
  application config when the option is absent.
  """
  @spec publish([topic_record(), ...], keyword()) :: result()
  def publish(records, options) when is_list(records) and is_list(options) do
    count = length(records)
    Assert.condition(count >= 1, "records must hold at least 1 record")

    Assert.condition(
      count <= @record_count_max,
      "records must hold at most #{@record_count_max} records, got: #{count}"
    )

    Enum.each(records, &assert_record/1)
    {backend, backend_options} = Keyword.pop_lazy(options, :backend, &configured_backend/0)
    Assert.condition(is_atom(backend), "backend must be a module, got: #{inspect(backend)}")
    Assert.condition(backend != nil, "no backend is configured for #{inspect(__MODULE__)}")

    records
    |> backend.publish(backend_options)
    |> assert_result(backend)
  end

  defp configured_backend do
    :gobusgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backend)
  end

  # The messages name the field and never its value, so a payload cannot leak
  # through a failed assertion.
  defp assert_record(%{topic: topic, key: key, value: value, headers: headers}) do
    Assert.condition(is_binary(topic), "topic must be a string")
    Assert.condition(topic != "", "topic must be non-empty")
    Assert.condition(is_binary(key), "key must be a string")
    Assert.condition(is_binary(value), "value must be a binary")
    Assert.condition(is_list(headers), "headers must be a list")

    Assert.condition(
      Enum.all?(headers, &match?({name, text} when is_binary(name) and is_binary(text), &1)),
      "headers must be pairs of strings"
    )
  end

  defp assert_result(:ok, _backend), do: :ok

  defp assert_result({:error, reason} = result, backend) do
    Assert.condition(
      reason in @error_reasons,
      "#{inspect(backend)} returned an undocumented error: #{inspect(reason)}"
    )

    result
  end

  defp assert_result(other, backend) do
    raise Assert.AssertionError,
      message: "#{inspect(backend)} returned off-contract: #{inspect(other)}"
  end
end
