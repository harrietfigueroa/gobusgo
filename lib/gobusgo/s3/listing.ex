defmodule Gobusgo.S3.Listing do
  @moduledoc """
  The XML bodies S3 answers with, parsed with OTP's `xmerl`: the body of a
  `ListObjectsV2` response and the body of an error response. Everything
  here is pure.

  A listing is requested with `encoding-type=url`, so its keys arrive
  percent-encoded and `parse/1` decodes them. A body that declares a
  document type is refused before it is parsed, so no entity it defines is
  expanded.
  """

  require Record

  @xmerl_header "xmerl/include/xmerl.hrl"

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: @xmerl_header)
  )

  Record.defrecordp(:xml_text, :xmlText, Record.extract(:xmlText, from_lib: @xmerl_header))

  @type t :: %{keys: [String.t()], continuation_token: String.t() | nil}

  @doc """
  Returns the keys of a `ListObjectsV2` body in the order it lists them, and
  the token that continues a truncated listing, `nil` for a complete one.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :malformed}
  def parse(body) when is_binary(body) do
    with {:ok, root} <- root(body, :ListBucketResult),
         {:ok, truncated} <- truncated(root),
         {:ok, continuation_token} <- continuation_token(root, truncated) do
      keys =
        for contents <- children(root, :Contents), key <- children(contents, :Key) do
          key |> text() |> URI.decode()
        end

      {:ok, %{keys: keys, continuation_token: continuation_token}}
    end
  end

  @doc "Returns the `Code` of an error body, or `:error` for any other body."
  @spec error_code(binary()) :: {:ok, String.t()} | :error
  def error_code(body) when is_binary(body) do
    with {:ok, root} <- root(body, :Error),
         [code] <- children(root, :Code) do
      {:ok, text(code)}
    else
      _other -> :error
    end
  end

  defp root(body, name) do
    if String.contains?(body, "<!DOCTYPE") do
      {:error, :malformed}
    else
      case scan(body) do
        {:ok, xml_element(name: ^name) = root} -> {:ok, root}
        _other -> {:error, :malformed}
      end
    end
  end

  # xmerl exits on a body that is not well-formed.
  defp scan(body) do
    {root, _rest} = :xmerl_scan.string(:erlang.binary_to_list(body), quiet: true)
    {:ok, root}
  catch
    :exit, _reason -> :error
  end

  defp truncated(root) do
    case children(root, :IsTruncated) do
      [element] ->
        case text(element) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _other -> {:error, :malformed}
        end

      _other ->
        {:error, :malformed}
    end
  end

  defp continuation_token(_root, false), do: {:ok, nil}

  defp continuation_token(root, true) do
    case children(root, :NextContinuationToken) do
      [element] -> {:ok, text(element)}
      _other -> {:error, :malformed}
    end
  end

  defp children(xml_element(content: content), name) do
    for xml_element(name: ^name) = child <- content, do: child
  end

  defp text(xml_element(content: content)) do
    for xml_text(value: value) <- content, into: "", do: List.to_string(value)
  end
end
