defmodule Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent do
  alias Gobusgo.CloudEvent

  @dataset "oba/agencies-with-coverage"
  @topic "oba.agencies-with-coverage.response-stored"
  @type_name CloudEvent.type(%{name: "response.stored", version: 1})

  @moduledoc """
  The "response stored" record of one stored agency discovery response: a
  reference to the stored response, never its content. Everything here is
  pure.

  The record goes to the topic `#{@topic}` under the key `#{@dataset}`, one
  key for the whole dataset, so the events of the dataset keep their order.
  It holds one `Gobusgo.CloudEvent`:

    * `type`: `#{@type_name}`.
    * `id`: the event identifier, a UUID version 7.
    * `source` and `time`: the producer and the time the producer gives.
    * `subject`: the destination of the stored response.
    * `data.dataset`: `#{@dataset}`.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.requestId`: the request identifier of the fetch.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `record/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @data_schema {:map,
                %{
                  "dataset" => {:literal, @dataset},
                  "destination" => :string,
                  "fetchedAt" => :string,
                  "dataSha256" => :string,
                  "requestId" => :string
                }}

  @type response :: %{
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type decoded :: %{
          event_id: RequestId.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t()
        }

  @type request :: %{
          event_id: RequestId.t(),
          source: String.t(),
          time: DateTime.t(),
          response: response()
        }

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The name of the agency discovery dataset."
  @spec dataset() :: String.t()
  def dataset, do: @dataset

  @doc """
  Returns the record that announces `request.response` as stored. Raises
  `Gobusgo.Assert.AssertionError` when an identifier is not a UUID version 7.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{event_id: event_id, source: source, time: time, response: response}) do
    %{
      destination: destination,
      fetched_at: %DateTime{} = fetched_at,
      data_sha256: data_sha256,
      request_id: request_id
    } = response

    Assert.condition(RequestId.valid?(event_id), "event identifier must be a UUID version 7")
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")

    CloudEvent.record(@topic, %{
      id: event_id,
      source: source,
      type: @type_name,
      time: time,
      subject: destination,
      partition_key: @dataset,
      data: %{
        "dataset" => @dataset,
        "destination" => destination,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "dataSha256" => data_sha256,
        "requestId" => request_id
      }
    })
  end

  @doc """
  Returns the event identifier and the stored response that `value`, the
  value of a record `record/1` produces, refers to. Fields of `data` outside
  the event are ignored. The first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{id: event_id, type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @type_name -> decode_data(event_id, data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_data(event_id, data) do
    with nil <- Schema.mismatch(data, @data_schema),
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
         request_id: request_id
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end
end
