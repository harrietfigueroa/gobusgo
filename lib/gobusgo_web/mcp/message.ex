defmodule GobusgoWeb.Mcp.Message do
  @moduledoc """
  The JSON-RPC message in the body of an MCP request. Everything here is
  pure.

  A body is one request, which has an `id`, or one notification, which has
  none. A batch, a response, and a message whose `id` is null or not a string
  or an integer are refused, since the transport carries a single request or
  notification and the protocol allows no null `id`. A refusal carries the
  `id` of the message where it is readable, and `nil` where it is not.
  """

  alias GobusgoWeb.Mcp.Error

  @type id :: String.t() | integer()

  @type request :: %{kind: :request, id: id(), method: String.t(), params: map()}

  @type notification :: %{kind: :notification, method: String.t(), params: map()}

  @type refusal :: %{error: Error.t(), id: id() | nil}

  # https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#sending-messages-to-the-server — checked 2026-11-11
  # https://modelcontextprotocol.io/specification/2026-07-28/basic/index#requests — checked 2026-11-11
  @envelope_schema {:map,
                    %{
                      "jsonrpc" => {:literal, "2.0"},
                      "method" => :string,
                      "params" => {:optional, {:map, %{}}}
                    }}

  @doc "The request or notification `body` holds, or the refusal to answer it with."
  @spec parse(binary()) :: {:ok, request() | notification()} | {:error, refusal()}
  def parse(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, message} when is_map(message) ->
        classify(message)

      {:ok, batch} when is_list(batch) ->
        refuse(Error.invalid_request("Batches are not supported"))

      {:ok, _scalar} ->
        refuse(Error.invalid_request("The message must be a JSON object"))

      {:error, _reason} ->
        refuse(Error.parse_error())
    end
  end

  defp classify(message) do
    id = readable_id(message)

    case Gobusgo.Schema.mismatch(message, @envelope_schema) do
      nil -> by_id(message, id)
      %{path: ["params" | _rest]} -> refuse(Error.invalid_params("params must be an object"), id)
      %{path: path} -> refuse(Error.invalid_request(envelope_message(path)), id)
    end
  end

  # A message that names an `id` it cannot be answered under is refused.
  defp by_id(%{"id" => _given}, nil) do
    refuse(Error.invalid_request("id must be a string or an integer"))
  end

  defp by_id(%{"id" => _given} = message, id) do
    {:ok, %{kind: :request, id: id, method: message["method"], params: params(message)}}
  end

  defp by_id(message, nil) do
    {:ok, %{kind: :notification, method: message["method"], params: params(message)}}
  end

  defp params(message) do
    case message do
      %{"params" => params} -> params
      %{} -> %{}
    end
  end

  defp readable_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp readable_id(%{}), do: nil

  defp envelope_message(path) do
    "The message does not match JSON-RPC 2.0 at #{Gobusgo.Schema.format_path(path)}"
  end

  defp refuse(error, id \\ nil), do: {:error, %{error: error, id: id}}
end
