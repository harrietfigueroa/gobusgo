defmodule Gobusgo.Gbfs.RawVehicleStatus do
  @destination_prefix "raw/gbfs/free-bike-status"
  @system_segment_prefix "system="
  @version_prefix "v"

  @moduledoc """
  The stored form of one fetched GBFS vehicle file, `free_bike_status` or
  `vehicle_status`: its logical destination and its content. Everything here
  is pure, so the stored form is a function of the fetch and the request
  identifier alone.

  ## Destination

      #{@destination_prefix}/dt=YYYY-MM-DD/#{@system_segment_prefix}<system>/<fetchedAt>_<requestId>_#{@version_prefix}<version>_<bodyHash12>.json.gz

    * `dt` is the UTC date of the fetch time.
    * `system` is the system identifier of `Gobusgo.Gbfs.Systems`.
    * `fetchedAt` is the fetch time in UTC basic ISO 8601 at second
      precision, such as `20261108T120000Z`.
    * `requestId` is the fetch's UUID version 7.
    * `version` is the GBFS version that answered, such as `3.0`, which
      decides the format the file is read in.
    * `bodyHash12` is the first 12 characters of the lowercase hexadecimal
      SHA-256 of the content.

  Names within a partition sort by fetch time. The `.gz` ending makes the
  writer store the content compressed.

  ## Content

  The vehicle file as the client received it, once expanded, byte for byte.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Compression
  alias Gobusgo.Destination
  alias Gobusgo.Gbfs.Client
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.RequestId

  @extension ".json" <> Compression.suffix()
  @hash_prefix_size 12
  @utc_time_zone "Etc/UTC"

  @type t :: %{
          destination: String.t(),
          content: binary(),
          system_id: String.t(),
          version: Files.version(),
          fetched_at: DateTime.t(),
          request_id: RequestId.t(),
          body_sha256: String.t()
        }

  @typedoc "What a destination of this dataset names."
  @type named :: %{
          system_id: String.t(),
          version: Files.version(),
          fetched_at: DateTime.t(),
          request_id: RequestId.t(),
          body_hash_prefix: String.t()
        }

  @doc "The prefix every destination of this dataset starts with."
  @spec destination_prefix() :: String.t()
  def destination_prefix, do: @destination_prefix

  @doc "The prefix every destination of `system_id` fetched on the UTC `date` starts with."
  @spec partition_prefix(String.t(), Date.t()) :: String.t()
  def partition_prefix(system_id, %Date{} = date) do
    Systems.assert_id(system_id)

    Enum.join(
      [@destination_prefix, "dt=" <> Date.to_iso8601(date), @system_segment_prefix <> system_id],
      "/"
    ) <> "/"
  end

  @doc """
  Returns the destination and content that store `fetched`, a vehicle file
  as `Gobusgo.Gbfs.Client.fetch/3` returns it, of the system `system_id`
  under `request_id`. Raises `Gobusgo.Assert.AssertionError` when the
  system identifier, the request identifier, the version, or the fetch time
  breaks its contract.
  """
  @spec build(%{system_id: String.t(), fetched: Client.fetched(), request_id: RequestId.t()}) ::
          t()
  def build(%{system_id: system_id, fetched: fetched, request_id: request_id}) do
    %{version: version, body: body, fetched_at: %DateTime{} = fetched_at} = fetched
    Systems.assert_id(system_id)
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(version in Files.versions(), "version must be known: #{inspect(version)}")
    Assert.condition(is_binary(body), "body must be a binary")
    Assert.condition(fetched_at.time_zone == @utc_time_zone, "fetch time must be in UTC")
    fetched_at = DateTime.truncate(fetched_at, :second)
    body_sha256 = body_sha256(body)

    name =
      Enum.join(
        [
          DateTime.to_iso8601(fetched_at, :basic),
          request_id,
          @version_prefix <> version,
          binary_part(body_sha256, 0, @hash_prefix_size)
        ],
        "_"
      ) <> @extension

    destination = partition_prefix(system_id, DateTime.to_date(fetched_at)) <> name

    Assert.condition(
      match?({:ok, _segments}, Destination.validate(destination)),
      "built an invalid destination"
    )

    Assert.condition(
      match?({:ok, _named}, parse_destination(destination)),
      "built an unreadable name"
    )

    %{
      destination: destination,
      content: body,
      system_id: system_id,
      version: version,
      fetched_at: fetched_at,
      request_id: request_id,
      body_sha256: body_sha256
    }
  end

  @doc "The lowercase hexadecimal SHA-256 of `body`."
  @spec body_sha256(binary()) :: String.t()
  def body_sha256(body) when is_binary(body) do
    :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
  end

  @doc """
  Returns what `destination` names, or `:error` for a destination that is
  not one `build/1` produces.
  """
  @spec parse_destination(String.t()) :: {:ok, named()} | :error
  def parse_destination(destination) when is_binary(destination) do
    with [date_segment, system_segment, name] <- segments_under_prefix(destination),
         "dt=" <> date_text <- date_segment,
         {:ok, date} <- Date.from_iso8601(date_text),
         @system_segment_prefix <> system_id <- system_segment,
         true <- Systems.id?(system_id),
         {:ok, named} <- parse_name(name),
         true <- DateTime.to_date(named.fetched_at) == date do
      {:ok, Map.put(named, :system_id, system_id)}
    else
      _other -> :error
    end
  end

  @doc """
  Returns `:ok` when `content` hashes to the hash `named`, what its
  destination names, carries, and `{:error, :hash_mismatch}` otherwise.
  """
  @spec check_content(named(), binary()) :: :ok | {:error, :hash_mismatch}
  def check_content(%{body_hash_prefix: body_hash_prefix}, content) when is_binary(content) do
    hash_prefix = binary_part(body_sha256(content), 0, @hash_prefix_size)

    if hash_prefix == body_hash_prefix do
      :ok
    else
      {:error, :hash_mismatch}
    end
  end

  defp segments_under_prefix(destination) do
    prefix = @destination_prefix <> "/"

    if String.starts_with?(destination, prefix) do
      rest =
        binary_part(destination, byte_size(prefix), byte_size(destination) - byte_size(prefix))

      String.split(rest, "/")
    else
      []
    end
  end

  defp parse_name(name) do
    with true <- String.ends_with?(name, @extension),
         stem = binary_part(name, 0, byte_size(name) - byte_size(@extension)),
         [stamp, request_id, @version_prefix <> version, hash_prefix] <- String.split(stem, "_"),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(stamp, :basic),
         true <- RequestId.valid?(request_id),
         true <- version in Files.versions(),
         true <- byte_size(hash_prefix) == @hash_prefix_size do
      {:ok,
       %{
         version: version,
         fetched_at: fetched_at,
         request_id: request_id,
         body_hash_prefix: hash_prefix
       }}
    else
      _other -> :error
    end
  end
end
