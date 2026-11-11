defmodule GobusgoWeb.Mcp.Error do
  @moduledoc """
  The JSON-RPC errors the MCP endpoint answers, each with the HTTP status it
  travels under. Everything here is pure.

  An error is a known outcome of a request, returned as a value and never
  raised. Its codes are the JSON-RPC 2.0 ones, `-32700` to `-32603`, and the
  three the 2026-07-28 revision defines, `-32020` to `-32022`; `-32002` is
  the resource-not-found code of the revisions before it.

  The status depends on the revision where the revisions disagree: a method
  the 2026-07-28 revision does not know is `404`, and `200` to a client of
  2025-11-25, which gives a `404` the meaning of an ended session
  (https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#session-management
  — checked 2026-11-11).
  """

  # https://www.jsonrpc.org/specification#error_object — checked 2026-11-11
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # https://modelcontextprotocol.io/specification/2026-07-28/basic/index#error-codes — checked 2026-11-11
  @header_mismatch -32_020
  @unsupported_protocol_version -32_022

  # https://modelcontextprotocol.io/specification/2025-11-25/server/resources#error-handling — checked 2026-11-11
  @resource_not_found_legacy -32_002

  @type revision :: :legacy | :modern

  @type t :: %{
          required(:code) => integer(),
          required(:message) => String.t(),
          required(:status) => pos_integer(),
          optional(:data) => map()
        }

  @doc "The body was not JSON."
  @spec parse_error() :: t()
  def parse_error, do: %{code: @parse_error, message: "Parse error", status: 400}

  @doc "The body was JSON and not a single JSON-RPC request or notification."
  @spec invalid_request(String.t()) :: t()
  def invalid_request(message) when is_binary(message) do
    %{code: @invalid_request, message: message, status: 400}
  end

  @doc "The request's `Origin` header does not name the public host."
  @spec origin_refused() :: t()
  def origin_refused, do: %{code: @invalid_request, message: "Origin not allowed", status: 403}

  @doc "The body is larger than the endpoint reads."
  @spec payload_too_large() :: t()
  def payload_too_large do
    %{code: @invalid_request, message: "Request body too large", status: 413}
  end

  @doc "No method of the revision has the name of `method`."
  @spec method_not_found(String.t(), revision()) :: t()
  def method_not_found(method, revision) when is_binary(method) do
    %{
      code: @method_not_found,
      message: "Method not found: #{method}",
      status: not_found(revision)
    }
  end

  @doc "The params of a well-formed request name something the server does not have, or break its schema."
  @spec invalid_params(String.t()) :: t()
  def invalid_params(message) when is_binary(message) do
    %{code: @invalid_params, message: message, status: 200}
  end

  @doc "`invalid_params/1` with the `data` the revision's example attaches."
  @spec invalid_params(String.t(), map()) :: t()
  def invalid_params(message, data) when is_binary(message) and is_map(data) do
    %{code: @invalid_params, message: message, status: 200, data: data}
  end

  @doc "A request of the 2026-07-28 revision lacks a field the revision requires of every request."
  @spec malformed_request(String.t()) :: t()
  def malformed_request(message) when is_binary(message) do
    %{code: @invalid_params, message: message, status: 400}
  end

  @doc "The headers of a request disagree with its body, or a required header is missing."
  @spec header_mismatch(String.t()) :: t()
  def header_mismatch(message) when is_binary(message) do
    %{code: @header_mismatch, message: message, status: 400}
  end

  @doc "The request names a revision the server does not speak."
  @spec unsupported_protocol_version(String.t(), [String.t()]) :: t()
  def unsupported_protocol_version(requested, supported)
      when is_binary(requested) and is_list(supported) do
    %{
      code: @unsupported_protocol_version,
      message: "Unsupported protocol version",
      status: 400,
      data: %{"supported" => supported, "requested" => requested}
    }
  end

  @doc "The resource at `uri` is not one the server has."
  @spec resource_not_found(String.t(), revision()) :: t()
  def resource_not_found(uri, :legacy) when is_binary(uri) do
    %{
      code: @resource_not_found_legacy,
      message: "Resource not found",
      status: 200,
      data: %{"uri" => uri}
    }
  end

  def resource_not_found(uri, :modern) when is_binary(uri) do
    %{
      code: @invalid_params,
      message: "Resource not found",
      status: 200,
      data: %{"uri" => uri}
    }
  end

  @doc "The server failed to answer a request that was well formed."
  @spec internal_error(String.t()) :: t()
  def internal_error(message) when is_binary(message) do
    %{code: @internal_error, message: message, status: 500}
  end

  @doc "The JSON-RPC error response that answers the request `id`, `nil` where none could be read."
  @spec to_body(t(), String.t() | integer() | nil) :: %{String.t() => term()}
  def to_body(%{code: code, message: message} = error, id) do
    object = %{"code" => code, "message" => message}

    object =
      case error do
        %{data: data} -> Map.put(object, "data", data)
        %{} -> object
      end

    %{"jsonrpc" => "2.0", "id" => id, "error" => object}
  end

  # https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#protocol-version-header — checked 2026-11-11
  defp not_found(:modern), do: 404
  defp not_found(:legacy), do: 200
end
