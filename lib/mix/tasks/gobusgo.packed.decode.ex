defmodule Mix.Tasks.Gobusgo.Packed.Decode do
  @shortdoc "Prints a packed container file as JSON"

  @moduledoc """
  Reads a packed container, a `.bin.gz` stream or a `.bin` file, expands it
  within `--bytes-max` bytes, by default the most stored compressed content
  expands to, and prints its header and string table as JSON, and each
  section after the table as its byte length and its bytes in base64. With
  `--kind-module`, a module that implements `Gobusgo.Packed.Kind`, it prints
  what that module's `inspect/1` returns for the decoded container instead.

      mix gobusgo.packed.decode <file> [--bytes-max N] [--kind-module Module]

  The task does not start the application. A file it refuses exits with the
  reason.
  """

  use Mix.Task

  alias Gobusgo.Compression
  alias Gobusgo.Packed

  @usage "usage: mix gobusgo.packed.decode <file> [--bytes-max N] [--kind-module Module]"

  @impl Mix.Task
  def run(arguments) do
    {options, positional} =
      OptionParser.parse!(arguments, strict: [bytes_max: :integer, kind_module: :string])

    file =
      case positional do
        [file] -> file
        _other -> Mix.raise(@usage)
      end

    bytes_max = Keyword.get(options, :bytes_max, Compression.content_bytes_max())
    bytes = File.read!(file)

    case describe(%{file: file, bytes: bytes, bytes_max: bytes_max}) do
      {:ok, decoded} -> Mix.shell().info(JSON.encode!(printed(decoded, options)))
      {:error, reason} -> Mix.raise("#{file} refused: #{reason}")
    end
  end

  defp printed(decoded, options) do
    case Keyword.fetch(options, :kind_module) do
      {:ok, name} -> inspected(decoded, Module.concat([name]))
      :error -> description(decoded)
    end
  end

  defp inspected(decoded, kind_module) do
    Code.ensure_loaded!(kind_module)

    if function_exported?(kind_module, :inspect, 1) do
      kind_module.inspect(decoded)
    else
      Mix.raise("#{inspect(kind_module)} does not implement Gobusgo.Packed.Kind")
    end
  end

  @doc """
  Returns the container `input.bytes`, the content of `input.file`, decoded
  for any kind and version, expanded within `input.bytes_max` when the file
  name ends in the compression suffix.
  """
  @spec describe(%{file: String.t(), bytes: binary(), bytes_max: pos_integer()}) ::
          {:ok, Packed.decoded()} | {:error, atom()}
  def describe(%{file: file, bytes: bytes, bytes_max: bytes_max}) do
    with {:ok, expanded} <- expanded(file, bytes, bytes_max) do
      Packed.decode(expanded, %{kind: :any, versions: :any, section_count: :any})
    end
  end

  @doc "Returns the JSON-encodable description of `decoded`: its header, strings, and sections."
  @spec description(Packed.decoded()) :: map()
  def description(decoded) do
    %{
      "kind" => decoded.kind,
      "version" => decoded.version,
      "recordCount" => decoded.record_count,
      "strings" => Tuple.to_list(decoded.strings),
      "sections" =>
        for section <- decoded.sections do
          %{"byteLength" => byte_size(section), "base64" => Base.encode64(section)}
        end
    }
  end

  defp expanded(file, bytes, bytes_max) do
    if Compression.compressed?(file) do
      Packed.expand(bytes, bytes_max)
    else
      {:ok, bytes}
    end
  end
end
