defmodule Gobusgo.OneBusAway.StoredEvent do
  alias Gobusgo.CloudEvent

  @type_name CloudEvent.type(%{name: "response.stored", version: 1})

  @moduledoc """
  The "response stored" record the datasets share: a reference to one stored
  response, never its content. Everything here is pure.

  The record holds one `Gobusgo.CloudEvent`:

    * `type`: `#{@type_name}`.
    * `id`: the event identifier, a UUID version 7.
    * `source` and `time`: the producer and the time the producer gives.
    * `subject`: the destination of the stored response.
    * `data.dataset`: the name of the dataset.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.requestId`: the request identifier of the fetch.

  `data` also holds the dataset's own fields.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `record/1` produces for
      the dataset.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @type response :: %{
          required(:destination) => String.t(),
          required(:fetched_at) => DateTime.t(),
          required(:data_sha256) => String.t(),
          required(:request_id) => RequestId.t(),
          optional(atom()) => term()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          data: %{String.t() => term()}
        }

  @type request :: %{
          topic: String.t(),
          dataset: String.t(),
          key: String.t(),
          event_id: RequestId.t(),
          source: String.t(),
          time: DateTime.t(),
          response: response(),
          data: %{String.t() => term()}
        }

  @shared_fields ["dataset", "destination", "fetchedAt", "dataSha256", "requestId"]

  @doc """
  Returns the record that announces `request.response` as stored, on
  `request.topic` under `request.key`, with the dataset's own fields in
  `request.data`. Raises `Gobusgo.Assert.AssertionError` when an identifier
  is not a UUID version 7 or a dataset field has the name of a shared one.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, response: response, data: dataset_data} = request) do
    %{
      destination: destination,
      fetched_at: %DateTime{} = fetched_at,
      data_sha256: data_sha256,
      request_id: request_id
    } = response

    %{topic: topic, dataset: dataset, key: key} = request
    Assert.condition(RequestId.valid?(event_id), "event identifier must be a UUID version 7")
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")

    Assert.condition(
      Enum.all?(@shared_fields, &(not is_map_key(dataset_data, &1))),
      "a dataset field must not have the name of a shared one"
    )

    CloudEvent.record(topic, %{
      id: event_id,
      source: request.source,
      type: @type_name,
      time: request.time,
      subject: destination,
      partition_key: key,
      data:
        Map.merge(dataset_data, %{
          "dataset" => dataset,
          "destination" => destination,
          "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
          "dataSha256" => data_sha256,
          "requestId" => request_id
        })
    })
  end

  @doc """
  Returns the event identifier and the stored response that `value`, the
  value of a record `record/1` produces for `dataset`, refers to, with the
  whole `data` of the event. The first rule the value breaks returns as a
  value.
  """
  @spec decode(binary(), String.t()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value, dataset) when is_binary(value) and is_binary(dataset) do
    with {:ok, %{id: event_id, type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @type_name -> decode_data(event_id, data, dataset)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_data(event_id, data, dataset) do
    schema =
      {:map,
       %{
         "dataset" => {:literal, dataset},
         "destination" => :string,
         "fetchedAt" => :string,
         "dataSha256" => :string,
         "requestId" => :string
       }}

    with nil <- Schema.mismatch(data, schema),
         %{"destination" => destination, "requestId" => request_id} = data,
         true <- destination != "",
         true <- RequestId.valid?(event_id),
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]) do
      {:ok,
       %{
         event_id: event_id,
         destination: destination,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         request_id: request_id,
         data: data
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end
end
