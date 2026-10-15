defmodule Gobusgo.OneBusAway.RawVehicleResponse do
  @destination_prefix "raw/oba/vehicles-for-agency"
  @agency_segment_prefix "agency="
  @escape "."

  @moduledoc """
  The stored form of one successful `vehicles-for-agency` response: its
  logical destination and its content. Everything here is pure, so the stored
  form is a function of the response and the request identifier alone. The
  parts every dataset shares are those of `Gobusgo.OneBusAway.RawResponse`.

  ## Destination

      #{@destination_prefix}/dt=YYYY-MM-DD/#{@agency_segment_prefix}<agency>/<fetchedAt>_<requestId>_<dataHash12>.json.gz

  `agency` is the agency identifier with every byte outside `A-Z`, `a-z`,
  `0-9`, `_`, and `-` written as `#{@escape}` and its two uppercase
  hexadecimal digits, so each identifier has one name and every name is a
  valid destination segment.

  ## Content

  The wrapper of `Gobusgo.OneBusAway.RawResponse`, whose `meta` also holds
  `agencyId`, the agency the request asked for.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.Situations
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.Vehicles
  alias Gobusgo.RequestId

  @type t :: RawResponse.t()

  @typedoc """
  One stored fetch, in the form `Gobusgo.OneBusAway.VehicleBatch.Records.build/1`
  takes, with the situations its response references and the count of
  those `Gobusgo.OneBusAway.Situations.parse/1` rejects.
  """
  @type parsed :: %{
          agency_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          vehicles: [Records.vehicle()],
          situations: [Situations.t()],
          situation_rejected_count: non_neg_integer()
        }

  @typedoc """
    * `:invalid_json` — the content is not JSON.
    * `:schema_mismatch` — the content is not the wrapper `build/1` produces,
      its `meta` names no agency, or its data is not vehicle data.
    * `:hash_mismatch` — the data does not hash to `meta.dataSha256`.
    * `:destination_mismatch` — `meta` names a destination other than the one
      the content was read from.
  """
  @type parse_error :: RawResponse.parse_error()

  @doc "The prefix every destination of this dataset starts with."
  @spec destination_prefix() :: String.t()
  def destination_prefix, do: @destination_prefix

  @doc """
  Returns the destination and content that store `response` under
  `request_id`, with the fetch time and data hash they carry. Raises
  `Gobusgo.Assert.AssertionError` when the agency identifier is empty or too
  long for a destination segment, and for everything
  `Gobusgo.OneBusAway.RawResponse.build/1` raises for.
  """
  @spec build(%{response: Vehicles.response(), request_id: RequestId.t()}) :: t()
  def build(%{response: %{agency_id: agency_id} = response, request_id: request_id}) do
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")

    RawResponse.build(%{
      response: response,
      request_id: request_id,
      prefix: @destination_prefix,
      segments: [agency_segment(agency_id)],
      meta: %{"agencyId" => agency_id}
    })
  end

  @doc """
  Returns the fetch that `content`, read back from `destination`, stored, in
  the form `Gobusgo.OneBusAway.VehicleBatch.Records.build/1` takes. The first
  rule the content breaks returns as a value. A situation that breaks a rule
  of `Gobusgo.OneBusAway.Situations` is counted and fails nothing.
  """
  @spec parse(%{destination: String.t(), content: binary()}) ::
          {:ok, parsed()} | {:error, parse_error()}
  def parse(%{destination: destination, content: content})
      when is_binary(destination) and is_binary(content) do
    raw =
      RawResponse.parse(%{
        destination: destination,
        content: content,
        prefix: @destination_prefix,
        segments: &segments/1
      })

    with {:ok, %{data: data, meta: %{"agencyId" => agency_id}} = stored} <- raw,
         {:ok, vehicles} <- parse_vehicles(data) do
      %{situations: situations, rejected_count: rejected_count} = Situations.parse(data)

      {:ok,
       %{
         agency_id: agency_id,
         destination: destination,
         fetched_at: stored.fetched_at,
         data_sha256: stored.data_sha256,
         request_id: stored.request_id,
         vehicles: vehicles,
         situations: situations,
         situation_rejected_count: rejected_count
       }}
    end
  end

  defp segments(meta) do
    case meta do
      %{"agencyId" => agency_id} when is_binary(agency_id) and agency_id != "" ->
        {:ok, [agency_segment(agency_id)]}

      _other ->
        :error
    end
  end

  defp parse_vehicles(data) do
    case Vehicles.parse(data) do
      {:ok, vehicles} -> {:ok, vehicles}
      {:error, _reason} -> {:error, :schema_mismatch}
    end
  end

  defp agency_segment(agency_id) do
    @agency_segment_prefix <> for(<<byte <- agency_id>>, into: "", do: escape(byte))
  end

  defp escape(byte) when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"_-" do
    <<byte>>
  end

  defp escape(byte), do: @escape <> Base.encode16(<<byte>>)
end
