defmodule Gobusgo.Deleter.S3 do
  @response_bytes_max 65_536

  @moduledoc """
  `Gobusgo.Deleter` backend that removes the object an S3 bucket holds for a
  destination, under the key `Gobusgo.S3.Key` gives it.

  ## Options

  `:prefix`, the key prefix, and the options of `Gobusgo.S3.Client.request/2`.
  Each defaults to its value under `config :gobusgo, Gobusgo.S3`.

  ## The deletion

  A `HeadObject` request, then a `DeleteObject` request for a key that holds
  an object. S3 answers a deletion of a key that holds no object as it
  answers one that removed an object, so the first request is what tells
  `:not_found` from `:ok`. A bucket has no hierarchy to leave empty, so
  `within` changes nothing here.

    * `HeadObject` 404: `:not_found`.
    * 403 to either request: `:permission_denied`.
    * `DeleteObject` 204: `:ok`.
    * 409, 500, 502, 503, and 504 after the client's retries, a network
      fault, the client's deadline, and unavailable credentials:
      `:io_failure`.

  Any other status raises `Gobusgo.Assert.AssertionError`.
  """

  @behaviour Gobusgo.Deleter

  alias Gobusgo.Assert
  alias Gobusgo.Destination
  alias Gobusgo.S3.Client
  alias Gobusgo.S3.Key

  @impl Gobusgo.Deleter
  def delete(%{destination: destination, within: within}, options)
      when is_binary(destination) and is_binary(within) and is_list(options) do
    client_options = Keyword.delete(options, :prefix)

    with {:ok, _segments} <- Destination.validate(destination),
         {:ok, %{remainder: ""}} <- Destination.validate_prefix(within),
         key = Key.from_destination(Key.prefix(options), destination),
         :ok <- key |> request(:head) |> Client.request(client_options) |> head_outcome() do
      key |> request(:delete) |> Client.request(client_options) |> delete_outcome()
    end
  end

  defp request(key, method) do
    %{
      method: method,
      key: key,
      query: [],
      headers: [],
      body: nil,
      bytes_max: @response_bytes_max,
      repeatable: true
    }
  end

  # https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadObject.html — checked 2026-10-11
  defp head_outcome({:ok, %{status: 200}}), do: :ok
  defp head_outcome({:ok, %{status: 404}}), do: {:error, :not_found}
  defp head_outcome(other), do: shared_outcome(other)

  # https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html — checked 2026-10-11
  defp delete_outcome({:ok, %{status: 204}}), do: :ok
  defp delete_outcome(other), do: shared_outcome(other)

  defp shared_outcome({:ok, %{status: 403}}), do: {:error, :permission_denied}

  defp shared_outcome({:ok, %{status: status}}) when status == 409 or status in 500..504 do
    {:error, :io_failure}
  end

  defp shared_outcome({:ok, %{status: status}}) do
    raise Assert.AssertionError, message: "S3 answered a deletion with status #{status}"
  end

  defp shared_outcome({:error, _fault}), do: {:error, :io_failure}
end
