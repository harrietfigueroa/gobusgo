defmodule Gobusgo.OneBusAway.RawRouteResponse do
  @destination_prefix "raw/oba/routes-for-agency"
  @agency_segment_prefix "agency="
  @escape "."

  @moduledoc """
  The stored form of one successful `routes-for-agency` response: its
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
  alias Gobusgo.OneBusAway.Routes
  alias Gobusgo.RequestId

  @type t :: RawResponse.t()

  @typedoc "One stored fetch of an agency's routes, as `parse/1` returns it."
  @type parsed :: %{
          agency_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          routes: [Routes.route()]
        }

  @typedoc """
    * `:invalid_json` — the content is not JSON.
    * `:schema_mismatch` — the content is not the wrapper `build/1` produces,
      its `meta` names no agency, or its data is not route data.
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
  @spec build(%{response: Routes.response(), request_id: RequestId.t()}) :: t()
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
  Returns the fetch that `content`, read back from `destination`, stored. The first
  rule the content breaks returns as a value.
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
         {:ok, routes} <- parse_routes(data, agency_id) do
      {:ok,
       %{
         agency_id: agency_id,
         destination: destination,
         fetched_at: stored.fetched_at,
         data_sha256: stored.data_sha256,
         request_id: stored.request_id,
         routes: routes
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

  defp parse_routes(data, agency_id) do
    case Routes.parse(data, agency_id) do
      {:ok, routes} -> {:ok, routes}
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
