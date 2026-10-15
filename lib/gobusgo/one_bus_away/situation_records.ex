defmodule Gobusgo.OneBusAway.SituationRecords do
  @topic "oba.situations.state"
  @id_infix "/situations/"

  @moduledoc """
  The published form of the situations, the service alerts, of one fetch:
  one record that holds every situation the fetch's response references.
  Everything here is pure, so the record is a function of the stored
  response alone and a repeated build yields the same bytes.

  Each dataset whose responses reference situations has a module that names
  its source: the `type`, the CloudEvent `source`, the key prefix, and the
  field of `data` that holds the identifier its fetch is about. The record
  goes to the topic `#{@topic}` and holds one `Gobusgo.CloudEvent` whose
  `time` is the fetch time.

    * Key: the source's prefix and the identifier, so the newest record of
      an identifier replaces its earlier ones, the situations it no longer
      references included.
    * `id`: `<requestId>#{@id_infix}<key>`.
    * `subject`: the identifier.
    * `data.<identifier field>`: the identifier.
    * `data.situations`: the situations in the source's order, each as
      `Gobusgo.OneBusAway.Situations.to_data/1` writes it.
    * `data.dataSha256`, `data.destination`, `data.fetchedAt`,
      `data.requestId`: those of the stored response.

  A record holds at most `Gobusgo.OneBusAway.Situations.situation_count_max/0`
  situations, each identifier once.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CloudEvent
  alias Gobusgo.OneBusAway.Situations
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc "What names the records of one dataset."
  @type source :: %{
          type_name: String.t(),
          source: String.t(),
          key_prefix: String.t(),
          id_field: String.t()
        }

  @typedoc "One fetch's situations, about the fetch's identifier."
  @type fetch :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          situations: [Situations.t()]
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/2` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @doc "The topic the records go to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the record that publishes `fetch` under `source`. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7, the identifier is empty, a situation identifier repeats, or the
  situations exceed their bound.
  """
  @spec build(source(), fetch()) :: Publisher.topic_record()
  def build(
        source,
        %{id: id, request_id: request_id, fetched_at: %DateTime{} = fetched_at} = fetch
      ) do
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(id), "identifier must be a string")
    Assert.condition(id != "", "identifier must be non-empty")

    Assert.condition(
      distinct_bounded?(fetch.situations),
      "situations must be bounded and distinct"
    )

    key = source.key_prefix <> id

    data = %{
      source.id_field => id,
      "situations" => Enum.map(fetch.situations, &Situations.to_data/1),
      "dataSha256" => fetch.data_sha256,
      "destination" => fetch.destination,
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "requestId" => request_id
    }

    Assert.schema(data, data_schema(source))

    CloudEvent.record(@topic, %{
      id: request_id <> @id_infix <> key,
      source: source.source,
      type: source.type_name,
      time: fetched_at,
      subject: id,
      partition_key: key,
      data: data
    })
  end

  @doc """
  Returns the fetch that `value`, the value of a record `build/2` produces
  under `source`, holds. A record of another `type` is
  `{:error, :unsupported_type}`, and the first other rule the value breaks
  returns as a value.
  """
  @spec decode(source(), binary()) :: {:ok, fetch()} | {:error, decode_error()}
  def decode(%{type_name: type_name} = source, value) when is_binary(value) do
    with {:ok, %{type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        ^type_name -> decode_data(source, data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_data(source, data) do
    with nil <- Schema.mismatch(data, data_schema(source)),
         %{"requestId" => request_id} = data,
         id = Map.fetch!(data, source.id_field),
         true <- id != "",
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]),
         situations = Enum.map(data["situations"], &Situations.from_data/1),
         true <- distinct_bounded?(situations) do
      {:ok,
       %{
         id: id,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         situations: situations
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp data_schema(source) do
    {:map,
     %{
       source.id_field => :string,
       "situations" => {:list, Situations.data_schema()},
       "dataSha256" => :string,
       "destination" => :string,
       "fetchedAt" => :string,
       "requestId" => :string
     }}
  end

  defp distinct_bounded?(situations) do
    if length(situations) <= Situations.situation_count_max() do
      ids = Enum.map(situations, & &1.id)
      length(Enum.uniq(ids)) == length(ids)
    else
      false
    end
  end
end
