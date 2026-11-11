defmodule Gobusgo.Routing.TripPathIndex do
  @kind 2
  @version 1
  @section_count 2
  @sha256_bytes 32

  @moduledoc """
  The trip path index, kind #{@kind} of the packed container: the shards of
  one service date, one record per route in route identifier order, each
  naming the route, the path of its shard, and the shard's `byteSize` and
  `sha256`, the entry `Gobusgo.Packed.file_entry/2` gives it. Section 1 is
  one `u32` column of three blocks of one value per record, the route's
  string index, the path's string index, and the byte size, and section 2
  holds each record's SHA-256 as #{@sha256_bytes} raw bytes. The strings are
  the route identifiers and the paths. Everything here is pure;
  `lib/gobusgo/routing/AGENTS.md` holds the format.
  """

  @behaviour Gobusgo.Packed.Kind

  alias Gobusgo.Assert
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.StringTable

  @typedoc "One shard of the date: its route, its path, and the byte size and hexadecimal SHA-256 of its stream."
  @type shard :: %{
          route_id: String.t(),
          path: String.t(),
          byte_size: non_neg_integer(),
          sha256: String.t()
        }

  @doc "The kind number of a trip path index."
  @spec kind() :: pos_integer()
  def kind, do: @kind

  @doc "The versions of the index this module reads."
  @spec versions() :: [pos_integer()]
  def versions, do: [@version]

  @doc """
  Returns the expanded bytes of the index of `records`, at least one, whose
  routes are distinct. The records are written in route identifier order.
  """
  @spec build([shard()]) :: binary()
  def build([_first | _rest] = records) do
    ordered = Enum.sort_by(records, & &1.route_id)

    Assert.condition(
      length(Enum.uniq_by(ordered, & &1.route_id)) == length(ordered),
      "the routes of an index must be distinct"
    )

    {rows, strings} = Enum.map_reduce(ordered, StringTable.new(), &row/2)

    columns =
      Columns.encode(
        :u32,
        Enum.map(rows, &elem(&1, 0)) ++
          Enum.map(rows, &elem(&1, 1)) ++ Enum.map(rows, &elem(&1, 2))
      )

    Packed.encode(%{
      kind: @kind,
      version: @version,
      record_count: length(ordered),
      strings: StringTable.strings(strings),
      sections: [columns, Enum.map(ordered, &sha256_bytes/1)]
    })
  end

  defp row(record, strings) do
    {route_index, strings} = StringTable.intern(strings, record.route_id)
    {path_index, strings} = StringTable.intern(strings, record.path)
    {{route_index, path_index, record.byte_size}, strings}
  end

  defp sha256_bytes(%{sha256: sha256}) do
    {:ok, bytes} = Base.decode16(sha256, case: :lower)

    Assert.condition(
      byte_size(bytes) == @sha256_bytes,
      "a SHA-256 is #{@sha256_bytes} bytes, got: #{byte_size(bytes)}"
    )

    bytes
  end

  @doc "Returns the records the index `binary`, an expanded container, holds, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, [shard()]} | {:error, Packed.refusal() | :bad_index}
  def decode(binary) when is_binary(binary) do
    expectation = %{kind: @kind, versions: [@version], section_count: @section_count}

    with {:ok, decoded} <- Packed.decode(binary, expectation) do
      records(decoded)
    end
  end

  defp records(%{record_count: count, strings: strings, sections: [column_section, sha_section]}) do
    with {:ok, values} <- Columns.decode(:u32, column_section, count * 3),
         :ok <- check_sha_section(sha_section, count) do
      {route_indexes, rest} = Enum.split(values, count)
      {path_indexes, byte_sizes} = Enum.split(rest, count)
      hashes = for <<sha::binary-size(@sha256_bytes) <- sha_section>>, do: sha

      rows = Enum.zip([route_indexes, path_indexes, byte_sizes, hashes])
      build_records(rows, strings)
    end
  end

  defp check_sha_section(section, count) do
    if byte_size(section) == count * @sha256_bytes do
      :ok
    else
      {:error, :bad_section_size}
    end
  end

  defp build_records(rows, strings) do
    if Enum.all?(rows, &indexes_in_range?(&1, tuple_size(strings))) do
      shards =
        for {route_index, path_index, byte_size, sha} <- rows do
          %{
            route_id: elem(strings, route_index),
            path: elem(strings, path_index),
            byte_size: byte_size,
            sha256: Base.encode16(sha, case: :lower)
          }
        end

      distinct(shards)
    else
      {:error, :bad_index}
    end
  end

  # A route has one shard.
  defp distinct(shards) do
    if length(Enum.uniq_by(shards, & &1.route_id)) == length(shards) do
      {:ok, shards}
    else
      {:error, :bad_index}
    end
  end

  defp indexes_in_range?({route_index, path_index, _byte_size, _sha}, count) do
    route_index < count and path_index < count
  end

  @impl Gobusgo.Packed.Kind
  def inspect(decoded) do
    {:ok, records} = records(decoded)

    %{
      "kind" => "trip path index",
      "version" => decoded.version,
      "records" =>
        for record <- records do
          %{
            "routeId" => record.route_id,
            "path" => record.path,
            "byteSize" => record.byte_size,
            "sha256" => record.sha256
          }
        end
    }
  end
end
