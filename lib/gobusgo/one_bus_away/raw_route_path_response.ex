defmodule Gobusgo.OneBusAway.RawRoutePathResponse do
  @destination_prefix "raw/oba/stops-for-route"
  @route_segment_prefix "route="
  @escape "."

  @moduledoc """
  The stored form of one successful `stops-for-route` response: its
  logical destination and its content. Everything here is pure, so the stored
  form is a function of the response and the request identifier alone. The
  parts every dataset shares are those of `Gobusgo.OneBusAway.RawResponse`.

  ## Destination

      #{@destination_prefix}/dt=YYYY-MM-DD/#{@route_segment_prefix}<route>/<fetchedAt>_<requestId>_<dataHash12>.json.gz

  `route` is the route identifier with every byte outside `A-Z`, `a-z`,
  `0-9`, `_`, and `-` written as `#{@escape}` and its two uppercase
  hexadecimal digits, so each identifier has one name and every name is a
  valid destination segment.

  ## Content

  The wrapper of `Gobusgo.OneBusAway.RawResponse`, whose `meta` also holds
  `routeId`, the route the request asked for.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.RequestId

  @type t :: RawResponse.t()

  @typedoc "One stored fetch of a route's stops and paths, as `parse/1` returns it."
  @type parsed :: %{
          route_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          route_path: RoutePaths.route_path()
        }

  @typedoc """
    * `:invalid_json` — the content is not JSON.
    * `:schema_mismatch` — the content is not the wrapper `build/1` produces,
      its `meta` names no route, or its data is not that route's stops and
      paths.
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
  `Gobusgo.Assert.AssertionError` when the route identifier is empty or too
  long for a destination segment, and for everything
  `Gobusgo.OneBusAway.RawResponse.build/1` raises for.
  """
  @spec build(%{response: RoutePaths.response(), request_id: RequestId.t()}) :: t()
  def build(%{response: %{route_id: route_id} = response, request_id: request_id}) do
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")

    RawResponse.build(%{
      response: response,
      request_id: request_id,
      prefix: @destination_prefix,
      segments: [route_segment(route_id)],
      meta: %{"routeId" => route_id}
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

    with {:ok, %{data: data, meta: %{"routeId" => route_id}} = stored} <- raw,
         {:ok, route_path} <- parse_route_path(data, route_id) do
      {:ok,
       %{
         route_id: route_id,
         destination: destination,
         fetched_at: stored.fetched_at,
         data_sha256: stored.data_sha256,
         request_id: stored.request_id,
         route_path: route_path
       }}
    end
  end

  defp segments(meta) do
    case meta do
      %{"routeId" => route_id} when is_binary(route_id) and route_id != "" ->
        {:ok, [route_segment(route_id)]}

      _other ->
        :error
    end
  end

  defp parse_route_path(data, route_id) do
    case RoutePaths.parse(data, route_id) do
      {:ok, route_path} -> {:ok, route_path}
      {:error, _reason} -> {:error, :schema_mismatch}
    end
  end

  defp route_segment(route_id) do
    @route_segment_prefix <> for(<<byte <- route_id>>, into: "", do: escape(byte))
  end

  defp escape(byte) when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"_-" do
    <<byte>>
  end

  defp escape(byte), do: @escape <> Base.encode16(<<byte>>)
end
