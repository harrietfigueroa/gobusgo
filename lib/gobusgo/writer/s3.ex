defmodule Gobusgo.Writer.S3 do
  @content_bytes_max 16 * 1024 * 1024
  @response_bytes_max 65_536

  @moduledoc """
  `Gobusgo.Writer` backend that stores each destination as one object of an
  S3 bucket, under the key `Gobusgo.S3.Key` gives it.

  ## Options

  `:prefix`, the key prefix, and the options of `Gobusgo.S3.Client.request/2`.
  Each defaults to its value under `config :gobusgo, Gobusgo.S3`.

  ## The write

  One `PutObject` request with `If-None-Match: *`, which S3 applies only
  when the key holds no object, so the write is create-only, and an object
  appears whole or not at all. Content is at most #{@content_bytes_max}
  bytes.

  The request is sent once per answer: a network fault is not retried,
  because the object may be stored and a second request would then answer
  that it exists. Such a write returns `:io_failure` with the object stored
  or absent.

  ## Outcomes

    * 200: `:ok`.
    * 412: `:already_exists`.
    * 403: `:permission_denied`.
    * 404, a bucket that does not exist, and 409, 500, 502, 503, and 504
      after the client's retries: `:io_failure`.
    * A network fault, the client's deadline, and unavailable credentials:
      `:io_failure`.

  Any other status raises `Gobusgo.Assert.AssertionError`.
  """

  @behaviour Gobusgo.Writer

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.S3.Client
  alias Gobusgo.S3.Key

  @doc "Content bytes allowed in one write."
  @spec content_bytes_max() :: pos_integer()
  def content_bytes_max, do: @content_bytes_max

  @impl Gobusgo.Writer
  def write(%{destination: destination, content: content}, options)
      when is_binary(destination) and is_binary(content) and is_list(options) do
    {prefix, client_options} = pop_prefix(options)

    with :ok <- check_content_size(content),
         {:ok, _segments} <- Destination.validate(destination) do
      request = %{
        method: :put,
        key: Key.from_destination(prefix, destination),
        query: [],
        headers: [{"if-none-match", "*"}],
        body: content,
        bytes_max: @response_bytes_max,
        repeatable: false
      }

      request |> Client.request(client_options) |> outcome()
    end
  end

  defp pop_prefix(options), do: {Key.prefix(options), Keyword.delete(options, :prefix)}

  defp check_content_size(content) do
    if byte_size(content) <= @content_bytes_max do
      :ok
    else
      {:error, :content_too_large}
    end
  end

  # https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html — checked 2026-10-11
  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html — checked 2026-10-11
  defp outcome({:ok, %{status: 200}}), do: :ok
  defp outcome({:ok, %{status: 412}}), do: {:error, :already_exists}
  defp outcome({:ok, %{status: 403}}), do: {:error, :permission_denied}

  defp outcome({:ok, %{status: status}}) when status in [404, 409, 500, 502, 503, 504] do
    {:error, :io_failure}
  end

  defp outcome({:ok, %{status: status}}) do
    raise Assert.AssertionError, message: "S3 answered a write with status #{status}"
  end

  defp outcome({:error, _fault}), do: {:error, :io_failure}
end
