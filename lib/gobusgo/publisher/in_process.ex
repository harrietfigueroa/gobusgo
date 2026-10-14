defmodule Gobusgo.Publisher.InProcess do
  @moduledoc """
  A publisher backend that delivers records to subscribers inside the
  running application: function calls in the caller's process, with no
  broker and nothing stored.

  ## Subscribers

  The `:subscribers` option, or the application config key `:subscribers`
  under `Gobusgo.Publisher.InProcess`, maps a topic to a
  `{module, function, arguments}`. The backend calls the function with
  `arguments` followed by a list of record values and expects `:ok`. A
  subscriber that returns anything else, or raises, has broken that
  contract, and the publishing process fails with it.

  Records are delivered in publish order, each run of records for one topic
  in one call. Keys and headers are not delivered, and neither is a
  tombstone, which has no value: its topic still needs a subscriber.

  ## Outcomes

    * `:ok` — every subscriber returned `:ok`.
    * `{:error, :unknown_topic}` — a record names a topic without a
      subscriber. Records before it are delivered and records after it are
      not.
    * `{:error, :timeout}` — a subscriber exited with a call timeout.
    * `{:error, :unavailable}` — a subscriber exited for another reason,
      such as a process that is not running.
  """

  @behaviour Gobusgo.Publisher

  @type subscriber :: {module(), atom(), [term()]}

  @impl Gobusgo.Publisher
  def publish(records, options) when is_list(records) and is_list(options) do
    options = Keyword.validate!(options, [:subscribers])
    subscribers = Keyword.get_lazy(options, :subscribers, &configured_subscribers/0)

    records
    |> Enum.chunk_by(& &1.topic)
    |> Enum.reduce_while(:ok, fn [%{topic: topic} | _rest] = run, :ok ->
      case subscribers do
        %{^topic => subscriber} -> continue(deliver(subscriber, values(run)))
        _other -> {:halt, {:error, :unknown_topic}}
      end
    end)
  end

  defp values(run), do: for(%{value: value} <- run, value != "", do: value)

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  defp configured_subscribers do
    :gobusgo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:subscribers)
  end

  defp deliver(_subscriber, []), do: :ok

  defp deliver({module, function, arguments}, values) do
    :ok = apply(module, function, arguments ++ [values])
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end
end
