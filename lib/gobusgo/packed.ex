defmodule Gobusgo.Packed do
  @magic "GBPK"
  @header_bytes 16
  @suffix ".bin"
  @u16_max 65_535
  @u32_max 4_294_967_295

  @moduledoc """
  The packed container every published data file of a kind added after the
  routing snapshot uses. The expanded bytes are a #{@header_bytes}-byte
  header, little-endian: the magic `#{@magic}`, a `u16` kind version, a
  `u16` kind, a `u32` record count, and a `u32` reserved, zero. Sections
  follow, each a `u32` byte length and that many bytes. Section 0 is the
  string table of `Gobusgo.Packed.StringTable`; the kind fixes how many
  sections follow it and what each holds. A file is stored as one gzip
  stream at `<prefix>-<SHA-256 of the stream>#{@suffix}#{Gobusgo.Compression.suffix()}`.
  Everything here is pure. `lib/gobusgo/packed/AGENTS.md` holds the format.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Compression
  alias Gobusgo.Packed.Kinds
  alias Gobusgo.Packed.StringTable

  @typedoc """
  What `decode/2` refuses a file for. `:bad_varint`, `:bad_utf8`,
  `:bad_string_table`, `:bad_section_size`, and `:bad_position` are also
  what the section readers return.
  """
  @type refusal ::
          :bad_magic
          | :unknown_kind
          | :kind_mismatch
          | :unsupported_version
          | :reserved_not_zero
          | :truncated
          | :trailing_bytes
          | :section_count
          | :bad_varint
          | :bad_utf8
          | :bad_string_table
          | :bad_section_size
          | :bad_position

  @typedoc "What a reader expects of a file; `:any` accepts whatever the header names."
  @type expectation :: %{
          kind: non_neg_integer() | :any,
          versions: [pos_integer()] | :any,
          section_count: non_neg_integer() | :any
        }

  @typedoc "A decoded container; `sections` are the bytes after the string table."
  @type decoded :: %{
          kind: non_neg_integer(),
          version: non_neg_integer(),
          record_count: non_neg_integer(),
          strings: tuple(),
          sections: [binary()]
        }

  @typedoc "The stored form of a container: what the writer is given and what it stores."
  @type stored :: %{
          content: binary(),
          stream: binary(),
          byte_size: pos_integer(),
          sha256: String.t()
        }

  @doc "The bytes of a header."
  @spec header_bytes() :: pos_integer()
  def header_bytes, do: @header_bytes

  @doc """
  Returns the expanded bytes of a container of kind `input.kind` and version
  `input.version` with `input.record_count` records, `input.strings`, the
  unique entries of its string table, and `input.sections`, the sections the
  kind holds after it.
  """
  @spec encode(%{
          kind: non_neg_integer(),
          version: pos_integer(),
          record_count: non_neg_integer(),
          strings: [String.t()],
          sections: [iodata()]
        }) :: binary()
  def encode(%{
        kind: kind,
        version: version,
        record_count: record_count,
        strings: strings,
        sections: sections
      })
      when is_integer(kind) and is_integer(version) and is_integer(record_count) and
             is_list(strings) and is_list(sections) do
    Assert.condition(Kinds.fetch(kind) != :unknown, "the kind must be in the table, got: #{kind}")

    Assert.condition(
      version >= 1 and version <= @u16_max,
      "the version must fit 16 bits, got: #{version}"
    )

    Assert.condition(
      record_count >= 0 and record_count <= @u32_max,
      "the record count must fit 32 bits, got: #{record_count}"
    )

    body =
      for section <- [StringTable.encode(strings) | sections] do
        bytes = IO.iodata_to_binary(section)

        Assert.condition(
          byte_size(bytes) <= @u32_max,
          "a section must fit 32 bits, got: #{byte_size(bytes)}"
        )

        [<<byte_size(bytes)::little-32>>, bytes]
      end

    IO.iodata_to_binary([
      @magic,
      <<version::little-16, kind::little-16, record_count::little-32, 0::little-32>>,
      body
    ])
  end

  @doc """
  Returns the container `binary` holds, or the first rule it breaks. The
  header must name the kind `expectation.kind`, a version in
  `expectation.versions`, and `expectation.section_count` sections after the
  string table. A bad file is a value, never a raise.
  """
  @spec decode(binary(), expectation()) :: {:ok, decoded()} | {:error, refusal()}
  def decode(binary, %{kind: _kind, versions: _versions, section_count: _count} = expectation)
      when is_binary(binary) do
    with {:ok, header, body} <- split_header(binary),
         :ok <- check_header(header, expectation),
         {:ok, [table | sections]} <- split_sections(body, []),
         :ok <- check_section_count(sections, expectation.section_count),
         {:ok, strings} <- StringTable.decode(table) do
      {:ok, Map.merge(header, %{strings: List.to_tuple(strings), sections: sections})}
    else
      {:ok, []} -> {:error, :section_count}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp split_header(
         <<@magic, version::little-16, kind::little-16, record_count::little-32,
           reserved::little-32, body::binary>>
       ) do
    case {Kinds.fetch(kind), reserved} do
      {:unknown, _reserved} ->
        {:error, :unknown_kind}

      {{:ok, _kind}, 0} ->
        {:ok, %{kind: kind, version: version, record_count: record_count}, body}

      {{:ok, _kind}, _reserved} ->
        {:error, :reserved_not_zero}
    end
  end

  defp split_header(<<magic::binary-size(4), _rest::binary>>) when magic != @magic,
    do: {:error, :bad_magic}

  defp split_header(_short), do: {:error, :truncated}

  defp check_header(%{kind: kind, version: version}, expectation) do
    is_kind = expectation.kind == :any or expectation.kind == kind
    is_version = expectation.versions == :any or version in expectation.versions

    cond do
      not is_kind -> {:error, :kind_mismatch}
      not is_version -> {:error, :unsupported_version}
      true -> :ok
    end
  end

  defp split_sections(<<>>, sections), do: {:ok, Enum.reverse(sections)}

  defp split_sections(<<length::little-32, rest::binary>>, sections)
       when length <= byte_size(rest) do
    <<section::binary-size(^length), after_section::binary>> = rest
    split_sections(after_section, [section | sections])
  end

  defp split_sections(<<_length::little-32, _rest::binary>>, _sections), do: {:error, :truncated}
  defp split_sections(_short, _sections), do: {:error, :trailing_bytes}

  defp check_section_count(_sections, :any), do: :ok
  defp check_section_count(sections, count) when length(sections) == count, do: :ok
  defp check_section_count(_sections, _count), do: {:error, :section_count}

  @doc """
  Returns the stored form of the container `expanded`: `content`, which the
  writer is given and compresses itself, `stream`, the gzip stream it stores,
  and the byte size and lowercase hexadecimal SHA-256 of that stream. The
  writer's compression gives the same stream for the same content, so the
  stream hashed here is the one stored.
  """
  @spec stored(binary()) :: stored()
  def stored(expanded) when is_binary(expanded) do
    Assert.condition(
      byte_size(expanded) <= Compression.content_bytes_max(),
      "a container must expand to at most #{Compression.content_bytes_max()} bytes, got: #{byte_size(expanded)}"
    )

    stream = Compression.compress(expanded)

    %{
      content: expanded,
      stream: stream,
      byte_size: byte_size(stream),
      sha256: :crypto.hash(:sha256, stream) |> Base.encode16(case: :lower)
    }
  end

  @doc "Returns the destination of `stored` for kind `input.kind` under `input.directory`."
  @spec destination(%{directory: String.t(), kind: non_neg_integer(), stored: stored()}) ::
          String.t()
  def destination(%{directory: directory, kind: kind, stored: %{sha256: sha256}}) do
    {:ok, %{prefix: prefix}} = Kinds.fetch(kind)
    "#{directory}/#{prefix}-#{sha256}#{@suffix}#{Compression.suffix()}"
  end

  @doc """
  Returns the content of the gzip stream `stream`, which expands to at most
  `bytes_max` bytes, or why it does not.
  """
  @spec expand(binary(), pos_integer()) ::
          {:ok, binary()} | {:error, Compression.decompress_error()}
  def expand(stream, bytes_max) when is_binary(stream),
    do: Compression.decompress(stream, bytes_max)

  @doc "Returns the manifest entry of `stored` at `path`, the shape every published set uses."
  @spec file_entry(String.t(), stored()) :: %{String.t() => String.t() | non_neg_integer()}
  def file_entry(path, %{byte_size: byte_size, sha256: sha256}) when is_binary(path) do
    %{"path" => path, "byteSize" => byte_size, "sha256" => sha256}
  end
end
