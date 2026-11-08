defmodule Gobusgo.Gbfs.VehicleStatusBatch do
  @vehicle_count_max 30_000

  @moduledoc """
  Processes one stored GBFS vehicle file: the file at a destination, read
  through `Gobusgo.Reader` and published through `Gobusgo.Publisher` as one
  record that holds every vehicle of the fetch with the version that
  answered. This module orchestrates and logs; the stored form of the input
  lives in `Gobusgo.Gbfs.RawVehicleStatus`, the file format in
  `Gobusgo.Gbfs.Files`, and the published form in
  `Gobusgo.Gbfs.VehicleStatusBatch.Records`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, and a file with no vehicles publishes a fetch with no vehicles.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the
  `:system_id`, the `:version`, the `:request_id` and `:fetched_at` of the
  fetch, and the `:vehicle_count`.

  `{:error, failure}`, a `t:Gobusgo.OneBusAway.BatchFailure.t/0` whose
  `:stage` is `:read`, `:parse`, or `:publish_vehicles`. A destination this
  dataset does not name is a `:destination_mismatch`, content that does not
  hash to the hash the name carries a `:hash_mismatch`, content that is not
  JSON `:invalid_json`, and a file that breaks its version's format or holds
  more than #{@vehicle_count_max} vehicles a `:schema_mismatch`. Nothing is
  published for a failure at `:read` or `:parse`.

  A call that publishes logs once at `debug`. A failure returns to the
  caller and is not logged here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          system_id: String.t(),
          version: Files.version(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          vehicle_count: non_neg_integer()
        }

  @doc "The most vehicles one fetch may hold."
  @spec vehicle_count_max() :: pos_integer()
  def vehicle_count_max, do: @vehicle_count_max

  @doc "Publishes the vehicles of the file stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, BatchFailure.t()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])

    result =
      with {:ok, named} <- name(destination),
           {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, vehicle_status} <- parse(named, content),
           fetched = fetched(%{destination: destination, named: named, content: content}),
           record = Records.build_fetched(Map.merge(fetched, vehicle_status)),
           :ok <- publish(record, Keyword.fetch!(options, :publish_options)) do
        {:ok,
         %{
           destination: destination,
           system_id: named.system_id,
           version: named.version,
           request_id: named.request_id,
           fetched_at: named.fetched_at,
           vehicle_count: length(vehicle_status.vehicles)
         }}
      end

    with {:ok, published} <- result do
      Logger.debug("Shared vehicle batch published",
        destination: destination,
        request_id: published.request_id,
        version: published.version,
        vehicle_count: published.vehicle_count
      )
    end

    result
  end

  defp name(destination) do
    case RawVehicleStatus.parse_destination(destination) do
      {:ok, named} -> {:ok, named}
      :error -> {:error, BatchFailure.parse(:destination_mismatch)}
    end
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, BatchFailure.read(reason)}
    end
  end

  defp parse(named, content) do
    with :ok <- check_content(named, content),
         {:ok, document} <- decode(content),
         {:ok, vehicle_status} <- vehicle_status(named, document) do
      vehicle_count = length(vehicle_status.vehicles)

      if vehicle_count <= @vehicle_count_max do
        {:ok, vehicle_status}
      else
        {:error, BatchFailure.parse(:schema_mismatch)}
      end
    end
  end

  defp check_content(named, content) do
    case RawVehicleStatus.check_content(named, content) do
      :ok -> :ok
      {:error, :hash_mismatch} -> {:error, BatchFailure.parse(:hash_mismatch)}
    end
  end

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, BatchFailure.parse(:invalid_json)}
    end
  end

  defp vehicle_status(%{version: version}, document) do
    case Files.vehicle_status(%{version: version, document: document}) do
      {:ok, vehicle_status} -> {:ok, vehicle_status}
      {:error, _cause} -> {:error, BatchFailure.parse(:schema_mismatch)}
    end
  end

  defp fetched(%{destination: destination, named: named, content: content}) do
    %{
      kind: :fetched,
      id: named.system_id,
      version: named.version,
      data_sha256: RawVehicleStatus.body_sha256(content),
      destination: destination,
      fetched_at: named.fetched_at,
      request_id: named.request_id
    }
  end

  defp publish(record, publish_options) do
    case Publisher.publish([record], publish_options) do
      :ok -> :ok
      {:error, reason} -> {:error, BatchFailure.publish(:publish_vehicles, reason)}
    end
  end
end
