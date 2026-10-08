defmodule Gobusgo.Usage.Records do
  alias Gobusgo.Usage.UserAgent

  @schema_version 1
  @page_bytes_max 32
  @filter_field_count_max 4
  @filter_value_count_max 32
  @filter_value_bytes_max 64
  @file_record_count_max 5_000
  @prefix "usage/page-connections"

  @moduledoc """
  The record of one page connection that has ended, and the file a batch of
  records is stored as. Everything here is pure.

  A record holds when the page connected and for how long, the page, whether
  the connection was a later mount of a page the browser already had open,
  the last filter the page showed, and coarse facts of the client: its
  device class and browser family out of `#{inspect(UserAgent)}`, the bucket
  its viewport's width falls in, its language, and the host it came from. A
  fact the client did not supply is `nil`. A record names no visitor: its
  schema has no field for an address, a user agent, or an identifier.

  A record keeps at most #{@filter_field_count_max} fields of a filter, in
  field order, and of each at most #{@filter_value_count_max} values of at
  most #{@filter_value_bytes_max} bytes, and counts what it leaves out in
  `filterValueOmittedCount`.

  A file holds at most #{@file_record_count_max} records as one compressed
  JSON object, `meta` and `records`, under
  `#{@prefix}/dt=<date written>/`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson

  @type filter :: %{String.t() => [String.t()]}

  @typedoc "What a page knows of its connection when it connects."
  @type connection :: %{
          page: String.t(),
          reconnect: boolean() | nil,
          device_class: UserAgent.device_class(),
          browser_family: UserAgent.browser_family(),
          viewport_width_bucket: String.t() | nil,
          language: String.t() | nil,
          referrer_host: String.t() | nil
        }

  @type ended :: %{
          connection: connection(),
          filter: filter(),
          connected_at: DateTime.t(),
          duration_ms: non_neg_integer()
        }

  @type t :: %{String.t() => term()}

  @type file :: %{destination: String.t(), content: binary()}

  @fields [
    "browserFamily",
    "connectedAt",
    "deviceClass",
    "durationMs",
    "filter",
    "filterValueOmittedCount",
    "language",
    "page",
    "reconnect",
    "referrerHost",
    "viewportWidthBucket"
  ]

  @schema {:map,
           %{
             "browserFamily" => :string,
             "connectedAt" => :string,
             "deviceClass" => :string,
             "durationMs" => :integer,
             "filter" => {:map, %{}},
             "filterValueOmittedCount" => :integer,
             "language" => {:nullable, :string},
             "page" => :string,
             "reconnect" => {:nullable, :boolean},
             "referrerHost" => {:nullable, :string},
             "viewportWidthBucket" => {:nullable, :string}
           }}

  @doc "The prefix every file's destination starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The name of every field of a record, sorted."
  @spec fields() :: [String.t(), ...]
  def fields, do: @fields

  @doc "The schema every record matches."
  @spec schema() :: Gobusgo.Schema.t()
  def schema, do: @schema

  @doc "Records one file holds at most."
  @spec file_record_count_max() :: pos_integer()
  def file_record_count_max, do: @file_record_count_max

  @doc """
  The record of a connection that has ended. `connected_at` is in UTC, and
  `filter` is the last filter the page showed, each field with its values.
  """
  @spec build(ended()) :: t()
  def build(%{
        connection: %{page: page} = connection,
        filter: filter,
        connected_at: %DateTime{time_zone: "Etc/UTC"} = connected_at,
        duration_ms: duration_ms
      })
      when is_binary(page) and is_map(filter) and is_integer(duration_ms) do
    Assert.condition(page != "", "page must be non-empty")

    Assert.condition(
      byte_size(page) <= @page_bytes_max,
      "page must be at most #{@page_bytes_max} bytes"
    )

    Assert.condition(duration_ms >= 0, "duration_ms must be non-negative, got: #{duration_ms}")

    {kept, omitted_count} = bounded_filter(filter)

    record = %{
      "browserFamily" => connection.browser_family,
      "connectedAt" => DateTime.to_iso8601(connected_at),
      "deviceClass" => connection.device_class,
      "durationMs" => duration_ms,
      "filter" => kept,
      "filterValueOmittedCount" => omitted_count,
      "language" => connection.language,
      "page" => page,
      "reconnect" => connection.reconnect,
      "referrerHost" => connection.referrer_host,
      "viewportWidthBucket" => connection.viewport_width_bucket
    }

    Assert.schema(record, @schema)
    record
  end

  @doc """
  The file of `records`, written at `written_at` in UTC, under the name
  `file_id`, which the caller makes distinct from every other file's.
  """
  @spec file(%{records: [t(), ...], written_at: DateTime.t(), file_id: String.t()}) ::
          file()
  def file(%{
        records: [_first | _rest] = records,
        written_at: %DateTime{time_zone: "Etc/UTC"} = written_at,
        file_id: file_id
      })
      when is_binary(file_id) do
    record_count = length(records)

    Assert.condition(
      record_count <= @file_record_count_max,
      "a file holds at most #{@file_record_count_max} records, got: #{record_count}"
    )

    Enum.each(records, &Assert.schema(&1, @schema))

    content =
      CanonicalJson.encode(%{
        "meta" => %{
          "recordCount" => record_count,
          "schemaVersion" => @schema_version,
          "writtenAt" => DateTime.to_iso8601(written_at)
        },
        "records" => records
      })

    date = written_at |> DateTime.to_date() |> Date.to_iso8601()
    %{destination: "#{@prefix}/dt=#{date}/#{file_id}.json.gz", content: content}
  end

  # The filter inside its bounds, and the count of values left out: every
  # value of a field past the field bound, every value past a field's value
  # bound, and every value longer than the byte bound.
  defp bounded_filter(filter) do
    value_count = filter |> Map.values() |> Enum.sum_by(&length/1)

    kept =
      filter
      |> Enum.sort()
      |> Enum.take(@filter_field_count_max)
      |> Map.new(fn {field, values} when is_binary(field) and is_list(values) ->
        {field, values |> Enum.filter(&short_value?/1) |> Enum.take(@filter_value_count_max)}
      end)

    kept_count = kept |> Map.values() |> Enum.sum_by(&length/1)
    {kept, value_count - kept_count}
  end

  defp short_value?(value) when is_binary(value), do: byte_size(value) <= @filter_value_bytes_max
end
