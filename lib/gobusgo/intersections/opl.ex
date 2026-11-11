defmodule Gobusgo.Intersections.Opl do
  @moduledoc """
  Reads the lines of osmium's OPL format (`osmium cat -f opl`) that the
  intersections need: a way's tags and node identifiers, and a node's
  position. A line is fields separated by one space; a way's tags field
  starts with `T`, its nodes field with `N`, and a node's longitude and
  latitude are the `x` and `y` fields. A text in a tag is percent-encoded as
  `%<hexadecimal code point>%`. Everything here is pure, and a line it does
  not understand is a value, never a raise.
  """

  @type way :: %{id: integer(), tags: %{String.t() => String.t()}, node_ids: [integer()]}
  @type node_position :: %{id: integer(), lat: float(), lon: float()}

  @doc "The way a line holds, `:skip` for a line of another type, or `:malformed`."
  @spec way(String.t()) :: {:ok, way()} | :skip | :malformed
  def way(<<"w", rest::binary>>) do
    [id_text | fields] = String.split(rest, " ")

    with {id, ""} <- Integer.parse(id_text),
         {:ok, node_ids} <- node_ids(fields) do
      {:ok, %{id: id, tags: tags(fields), node_ids: node_ids}}
    else
      _malformed -> :malformed
    end
  end

  def way(line) when is_binary(line), do: :skip

  @doc "The node a line holds, `:skip` for a line of another type, or `:malformed`."
  @spec node(String.t()) :: {:ok, node_position()} | :skip | :malformed
  def node(<<"n", rest::binary>>) do
    [id_text | fields] = String.split(rest, " ")

    with {id, ""} <- Integer.parse(id_text),
         {:ok, lon} <- coordinate(fields, "x"),
         {:ok, lat} <- coordinate(fields, "y") do
      {:ok, %{id: id, lat: lat, lon: lon}}
    else
      _malformed -> :malformed
    end
  end

  def node(line) when is_binary(line), do: :skip

  @doc "The identifier a node line starts with, read without parsing the rest of the line."
  @spec node_id(String.t()) :: {:ok, integer()} | :skip | :malformed
  def node_id(<<"n", rest::binary>>) do
    [id_text | _fields] = String.split(rest, " ", parts: 2)

    case Integer.parse(id_text) do
      {id, ""} -> {:ok, id}
      _other -> :malformed
    end
  end

  def node_id(line) when is_binary(line), do: :skip

  defp coordinate(fields, prefix) do
    case Enum.find(fields, &String.starts_with?(&1, prefix)) do
      nil -> :error
      <<_prefix::binary-size(1), text::binary>> -> parse_degrees(text)
    end
  end

  defp parse_degrees(text) do
    case Float.parse(text) do
      {degrees, ""} -> {:ok, degrees}
      _other -> :error
    end
  end

  defp node_ids(fields) do
    case Enum.find(fields, &String.starts_with?(&1, "N")) do
      nil -> {:ok, []}
      "N" -> {:ok, []}
      <<"N", list::binary>> -> parse_node_ids(String.split(list, ","), [])
    end
  end

  defp parse_node_ids([], ids), do: {:ok, Enum.reverse(ids)}

  defp parse_node_ids([<<"n", text::binary>> | rest], ids) do
    case Integer.parse(text) do
      {id, ""} -> parse_node_ids(rest, [id | ids])
      _other -> :error
    end
  end

  defp parse_node_ids(_malformed, _ids), do: :error

  defp tags(fields) do
    case Enum.find(fields, &String.starts_with?(&1, "T")) do
      nil -> %{}
      "T" -> %{}
      <<"T", list::binary>> -> list |> String.split(",") |> Map.new(&tag/1)
    end
  end

  defp tag(text) do
    case String.split(text, "=", parts: 2) do
      [key, value] -> {decode(key), decode(value)}
      [key] -> {decode(key), ""}
    end
  end

  defp decode(text), do: Regex.replace(~r/%([0-9a-fA-F]{1,6})%/, text, &code_point/2)

  defp code_point(whole, hexadecimal) do
    code = String.to_integer(hexadecimal, 16)

    if code <= 0x10FFFF and code not in 0xD800..0xDFFF do
      <<code::utf8>>
    else
      whole
    end
  end
end
