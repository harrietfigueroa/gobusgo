defmodule Gobusgo.Reader.S3 do
  @content_bytes_max 16 * 1024 * 1024
  @listing_bytes_max 1024 * 1024
  @listing_key_count_max 100
  @page_count_max 100

  @moduledoc """
  `Gobusgo.Reader` backend that loads destinations from the objects of an S3
  bucket, under the keys `Gobusgo.S3.Key` gives them.

  ## Options

  `:prefix`, the key prefix, and the options of `Gobusgo.S3.Client.request/2`.
  Each defaults to its value under `config :gobusgo, Gobusgo.S3`.
  `:page_count_max` is the count of listing requests one `discover/2` call
  may make, #{@page_count_max} by default.

  ## Reading

  One `GetObject` request. An object larger than #{@content_bytes_max} bytes
  is `:content_too_large`.

    * 200: the content.
    * 404: `:not_found`.
    * 403: `:permission_denied`. S3 answers 403 for a key that holds no
      object when the role may not list the bucket.
    * 500, 502, 503, and 504 after the client's retries, a network fault,
      the client's deadline, and unavailable credentials: `:io_failure`.

  ## Discovery

  `ListObjectsV2` requests of at most #{@listing_key_count_max} keys each,
  consumed as a lazy stream of pages that follows the continuation token and
  stops once the page of destinations is full. The first request starts
  after the cursor, which is the last destination of the page before. A key
  whose remainder after the key prefix is no valid destination is left out.

  S3 lists keys in ascending order only. A descending discovery lists the
  whole prefix, then returns the page from its end, so it suits a prefix of
  at most #{@page_count_max * @listing_key_count_max} keys. A call that
  needs more than `:page_count_max` requests returns `:discovery_too_large`.

    * 200: a page. A body that is no listing is `:io_failure`.
    * 403: `:permission_denied`.
    * 404, a bucket that does not exist, and the failures of a read:
      `:io_failure`.

  Any other status raises `Gobusgo.Assert.AssertionError`.
  """

  @behaviour Gobusgo.Reader

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.S3.Client
  alias Gobusgo.S3.Key
  alias Gobusgo.S3.Listing

  @doc "Content bytes allowed in one read."
  @spec content_bytes_max() :: pos_integer()
  def content_bytes_max, do: @content_bytes_max

  @impl Gobusgo.Reader
  def read(destination, options) when is_binary(destination) and is_list(options) do
    %{prefix: prefix, client_options: client_options} = split(options)

    with {:ok, _segments} <- Destination.validate(destination) do
      request = %{
        method: :get,
        key: Key.from_destination(prefix, destination),
        query: [],
        headers: [],
        body: nil,
        bytes_max: @content_bytes_max,
        repeatable: true
      }

      request |> Client.request(client_options) |> read_outcome()
    end
  end

  # https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html — checked 2026-10-11
  defp read_outcome({:ok, %{status: 200, body: body}}), do: {:ok, body}
  defp read_outcome({:ok, %{status: 404}}), do: {:error, :not_found}
  defp read_outcome({:ok, %{status: 403}}), do: {:error, :permission_denied}
  defp read_outcome({:ok, %{status: status}}) when status in 500..504, do: {:error, :io_failure}

  defp read_outcome({:ok, %{status: status}}) do
    raise Assert.AssertionError, message: "S3 answered a read with status #{status}"
  end

  defp read_outcome({:error, :body_too_large}), do: {:error, :content_too_large}
  defp read_outcome({:error, _fault}), do: {:error, :io_failure}

  @impl Gobusgo.Reader
  def discover(%{prefix: prefix, limit: limit, order: order, cursor: cursor}, options)
      when is_binary(prefix) and is_integer(limit) and is_list(options) do
    Assert.condition(limit >= 1, "limit must be at least 1, got: #{limit}")
    context = split(options)

    with {:ok, _prefix} <- Destination.validate_prefix(prefix),
         :ok <- check_cursor(cursor) do
      case order do
        :ascending -> ascending(%{prefix: prefix, limit: limit, cursor: cursor}, context)
        :descending -> descending(%{prefix: prefix, limit: limit, cursor: cursor}, context)
      end
    end
  end

  defp split(options) do
    {page_count_max, options} = Keyword.pop(options, :page_count_max, @page_count_max)
    Assert.condition(is_integer(page_count_max), "page_count_max must be an integer")
    Assert.condition(page_count_max >= 1, "page_count_max must be at least 1")

    %{
      prefix: Key.prefix(options),
      client_options: Keyword.delete(options, :prefix),
      page_count_max: page_count_max
    }
  end

  defp check_cursor(nil), do: :ok

  defp check_cursor(cursor) when is_binary(cursor) do
    case Destination.validate(cursor) do
      {:ok, _segments} -> :ok
      {:error, {:invalid_destination, _reason}} -> {:error, :invalid_cursor}
    end
  end

  # Takes pages until the limit is reached. A further page exists when the
  # last page taken holds more destinations than the limit left room for, or
  # when S3 says its listing continues.
  defp ascending(%{limit: limit} = discovery, context) do
    start = %{found: [], more: false}

    discovery
    |> pages(discovery.cursor, context)
    |> Enum.reduce_while({:ok, start}, fn
      {:ok, %{destinations: destinations, last: last}}, {:ok, %{found: found}} ->
        found = found ++ destinations

        cond do
          length(found) > limit -> {:halt, {:ok, %{found: Enum.take(found, limit), more: true}}}
          length(found) == limit -> {:halt, {:ok, %{found: found, more: not last}}}
          true -> {:cont, {:ok, %{found: found, more: false}}}
        end

      {:error, reason}, _collected ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, %{found: found, more: more}} -> {:ok, page(found, more)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp descending(%{limit: limit, cursor: cursor} = discovery, context) do
    discovery
    |> pages(nil, context)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, %{destinations: destinations}}, {:ok, found} ->
        {:cont, {:ok, Enum.reverse(destinations, found)}}

      {:error, reason}, _found ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, newest_first} ->
        after_cursor = Enum.drop_while(newest_first, &(is_binary(cursor) and &1 >= cursor))
        {found, rest} = Enum.split(after_cursor, limit)
        {:ok, page(found, rest != [])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page(found, true), do: %{destinations: found, cursor: List.last(found)}
  defp page(found, false), do: %{destinations: found, cursor: nil}

  # A lazy stream of the listing's pages: each `{:ok, page}` with the
  # destinations of one response and whether it is the listing's last, or
  # one `{:error, reason}`, after which the stream ends.
  defp pages(%{prefix: prefix, limit: limit}, start_after, context) do
    query = [
      {"list-type", "2"},
      {"encoding-type", "url"},
      {"max-keys", Integer.to_string(min(limit, @listing_key_count_max))},
      {"prefix", Key.from_destination(context.prefix, prefix)}
    ]

    first =
      case start_after do
        nil -> query
        cursor -> query ++ [{"start-after", Key.from_destination(context.prefix, cursor)}]
      end

    Stream.resource(
      fn -> {:next, first, context.page_count_max} end,
      fn
        :done ->
          {:halt, :done}

        {:next, _query, 0} ->
          {[{:error, :discovery_too_large}], :done}

        {:next, page_query, pages_left} ->
          case list(page_query, context) do
            {:ok, %{keys: keys, continuation_token: nil}} ->
              {[{:ok, %{destinations: destinations(keys, context), last: true}}], :done}

            {:ok, %{keys: keys, continuation_token: token}} ->
              next = {:next, query ++ [{"continuation-token", token}], pages_left - 1}
              {[{:ok, %{destinations: destinations(keys, context), last: false}}], next}

            {:error, reason} ->
              {[{:error, reason}], :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp destinations(keys, %{prefix: prefix}) do
    Enum.flat_map(keys, fn key ->
      case Key.to_destination(prefix, key) do
        {:ok, destination} -> [destination]
        :error -> []
      end
    end)
  end

  defp list(query, %{client_options: client_options}) do
    request = %{
      method: :get,
      key: "",
      query: query,
      headers: [],
      body: nil,
      bytes_max: @listing_bytes_max,
      repeatable: true
    }

    request |> Client.request(client_options) |> list_outcome()
  end

  # https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html — checked 2026-10-11
  defp list_outcome({:ok, %{status: 200, body: body}}) do
    case Listing.parse(body) do
      {:ok, listing} -> {:ok, listing}
      {:error, :malformed} -> {:error, :io_failure}
    end
  end

  defp list_outcome({:ok, %{status: 403}}), do: {:error, :permission_denied}

  defp list_outcome({:ok, %{status: status}}) when status == 404 or status in 500..504 do
    {:error, :io_failure}
  end

  defp list_outcome({:ok, %{status: status}}) do
    raise Assert.AssertionError, message: "S3 answered a listing with status #{status}"
  end

  defp list_outcome({:error, _fault}), do: {:error, :io_failure}
end
