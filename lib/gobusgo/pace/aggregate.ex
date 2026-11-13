defmodule Gobusgo.Pace.Aggregate do
  @format_version 1
  @prefix "paces/daily"
  @precision 3
  @node_escape "."

  @moduledoc """
  The stored form of one node's pace table of one UTC day. Everything here is
  pure.

  ## Destination

      #{@prefix}/dt=YYYY-MM-DD/<node>-<fileId>.json.gz

  `node` is the node's name with every byte outside `A-Z`, `a-z`, `0-9`, `_`,
  and `-` written as `#{@node_escape}` and its two uppercase hexadecimal
  digits, and `fileId` a name no other file has, so two nodes, and two runs
  of one node, never write one destination.

  ## Content

  One JSON object of `meta` and `cells`, compressed as every `.gz`
  destination is.

    * `cells` maps `"<longitude cell>,<latitude cell>,<direction>"` to
      `[seconds, meters]`, each rounded to #{@precision} decimals. The
      longitude and latitude cells are the floors of the degrees over
      `meta.cellDegrees`, the direction is the initial bearing of the path
      segment in `meta.directionCount` buckets centered on north, clockwise.
      One table covers every hour of the day.
    * `meta.formatVersion` is #{@format_version}, and changes when a reader
      of version #{@format_version} would misread a file.
    * `meta` also holds `date`, `node`, `fileId`, `writtenAt`,
      `stepMeters`, `cellDegrees`, `directionCount`,
      `cellCount`, `metersTotal`, and `droppedCellCount`, the cells the
      table's bound left out.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Table

  @type file :: %{
          destination: String.t(),
          content: binary(),
          cell_count: non_neg_integer(),
          meters_total: number()
        }

  @doc "The prefix every file's destination starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The file of `input.table`, written at `input.written_at` by `input.node`."
  @spec build(%{
          table: Table.t(),
          node: String.t(),
          file_id: String.t(),
          written_at: DateTime.t()
        }) :: file()
  def build(%{table: %{date: date} = table, node: node, file_id: file_id, written_at: written_at})
      when is_binary(node) and is_binary(file_id) and node != "" and file_id != "" do
    cell_count = map_size(table.cells)
    meters_total = round_to_precision(Table.meters_total(table))

    cells =
      for {key, {seconds, meters}} <- table.cells,
          into: %{},
          do: encode_cell(key, seconds, meters)

    date_text = Date.to_iso8601(date)

    content =
      CanonicalJson.encode(%{
        "meta" => %{
          "cellCount" => cell_count,
          "cellDegrees" => %{
            "lat" => Learning.cell_degrees().lat,
            "lon" => Learning.cell_degrees().lon
          },
          "date" => date_text,
          "directionCount" => Learning.direction_count(),
          "droppedCellCount" => table.dropped_count,
          "fileId" => file_id,
          "formatVersion" => @format_version,
          "metersTotal" => meters_total,
          "node" => node,
          "stepMeters" => Learning.step_m(),
          "writtenAt" => DateTime.to_iso8601(written_at)
        },
        "cells" => cells
      })

    size = byte_size(content)

    Assert.condition(
      size <= Compression.content_bytes_max(),
      "a file holds at most #{Compression.content_bytes_max()} bytes, got: #{size}"
    )

    Assert.condition(
      map_size(cells) == cell_count,
      "every cell must have its own key, got #{map_size(cells)} for #{cell_count}"
    )

    destination = "#{@prefix}/dt=#{date_text}/#{escape(node)}-#{file_id}.json.gz"

    %{
      destination: destination,
      content: content,
      cell_count: cell_count,
      meters_total: meters_total
    }
  end

  defp encode_cell({lon_cell, lat_cell, direction}, seconds, meters) do
    {"#{lon_cell},#{lat_cell},#{direction}",
     [round_to_precision(seconds), round_to_precision(meters)]}
  end

  defp round_to_precision(value), do: Float.round(value * 1.0, @precision)

  defp escape(node), do: for(<<byte <- node>>, into: "", do: escape_byte(byte))

  defp escape_byte(byte)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"_-", do: <<byte>>

  defp escape_byte(byte), do: @node_escape <> Base.encode16(<<byte>>)
end
