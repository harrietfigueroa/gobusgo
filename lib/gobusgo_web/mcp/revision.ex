defmodule GobusgoWeb.Mcp.Revision do
  @moduledoc """
  The protocol revision a request speaks, and what the revision requires of
  the request. Everything here is pure.

  The endpoint speaks two eras. A `:modern` request, revision 2026-07-28,
  carries its revision, capabilities, and client in `params._meta`, and
  mirrors its revision, method, and target into the `MCP-Protocol-Version`,
  `Mcp-Method`, and `Mcp-Name` headers; the server checks the headers against
  the body. A `:legacy` request, revision 2025-11-25 and earlier, is one that
  names no revision in a header, as an `initialize` does, or names
  2025-11-25. Any other revision is refused with the revisions the server
  speaks.

  The headers arrive as what the controller read of them: each value, or
  `nil` for a header that was absent or sent more than once.
  """

  alias GobusgoWeb.Mcp.Error
  alias GobusgoWeb.Mcp.Message

  @modern "2026-07-28"
  @legacy "2025-11-25"

  @type revision :: :legacy | :modern

  @type headers :: %{
          protocol_version: String.t() | nil,
          method: String.t() | nil,
          name: String.t() | nil
        }

  @meta_protocol_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_capabilities "io.modelcontextprotocol/clientCapabilities"

  # https://modelcontextprotocol.io/specification/2026-07-28/basic/index#meta — checked 2026-11-11
  @meta_schema {:map,
                %{
                  "_meta" =>
                    {:map,
                     %{
                       @meta_protocol_version => :string,
                       @meta_client_capabilities => {:map, %{}}
                     }}
                }}

  # https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#request-metadata — checked 2026-11-11
  @name_methods %{"tools/call" => "name", "resources/read" => "uri", "prompts/get" => "name"}

  @base64_prefix "=?base64?"
  @base64_suffix "?="

  @doc "The revisions the server speaks, the newest first."
  @spec supported() :: [String.t(), ...]
  def supported, do: [@modern, @legacy]

  @doc "The revision a client that opens with `initialize` is answered with."
  @spec legacy() :: String.t()
  def legacy, do: @legacy

  @doc "The revision of `request` under `headers`, or the error that refuses it."
  @spec resolve(Message.request(), headers()) :: {:ok, revision()} | {:error, Error.t()}
  def resolve(%{kind: :request} = request, %{protocol_version: protocol_version} = headers) do
    case protocol_version do
      nil -> {:ok, :legacy}
      @legacy -> {:ok, :legacy}
      @modern -> modern(request, headers)
      other -> {:error, Error.unsupported_protocol_version(other, supported())}
    end
  end

  defp modern(request, headers) do
    case validate_modern(request, headers) do
      :ok -> {:ok, :modern}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_modern(%{params: params} = request, headers) do
    with nil <- Gobusgo.Schema.mismatch(params, @meta_schema),
         :ok <- check_meta_version(params),
         :ok <- check_method(request, headers) do
      check_name(request, headers)
    else
      %{path: path} ->
        message = "Missing or invalid " <> Gobusgo.Schema.format_path(path)
        {:error, Error.malformed_request(message)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_meta_version(%{"_meta" => meta}) do
    case Map.fetch!(meta, @meta_protocol_version) do
      @modern -> :ok
      _other -> {:error, Error.header_mismatch("The _meta protocol version is not #{@modern}")}
    end
  end

  defp check_method(%{method: method}, %{method: header}) do
    case header do
      ^method -> :ok
      nil -> {:error, Error.header_mismatch("The Mcp-Method header is missing")}
      _other -> {:error, Error.header_mismatch("The Mcp-Method header does not match the method")}
    end
  end

  defp check_name(%{method: method, params: params}, %{name: header}) do
    with {:ok, field} <- Map.fetch(@name_methods, method),
         target when is_binary(target) <- Map.get(params, field) do
      compare_name(target, header)
    else
      _no_target -> :ok
    end
  end

  defp compare_name(_target, nil),
    do: {:error, Error.header_mismatch("The Mcp-Name header is missing")}

  defp compare_name(target, header) do
    case decode_name(header) do
      {:ok, ^target} ->
        :ok

      _mismatch ->
        {:error, Error.header_mismatch("The Mcp-Name header does not match the target")}
    end
  end

  # The base64 form a client sends for a value that is not plain ASCII.
  # https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#value-encoding — checked 2026-11-11
  defp decode_name(@base64_prefix <> rest = header) do
    case String.ends_with?(rest, @base64_suffix) do
      true -> rest |> String.replace_suffix(@base64_suffix, "") |> Base.decode64()
      false -> {:ok, header}
    end
  end

  defp decode_name(header), do: {:ok, header}
end
