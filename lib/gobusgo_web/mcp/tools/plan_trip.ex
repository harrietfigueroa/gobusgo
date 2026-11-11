defmodule GobusgoWeb.Mcp.Tools.PlanTrip do
  @moduledoc """
  The `plan_trip` tool: the rider's words for the destination of a trip, for
  its start when the rider names one, and when it is for, which the trip
  planner app (`GobusgoWeb.Mcp.Resources.TripApp`) reads, resolves, and
  routes on the rider's device.

  The tool checks its arguments and returns them unchanged as
  `structuredContent`, with one line of text. It resolves no place, reads no
  schedule, and routes nothing, so the server holds no search and no
  routing for it.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias GobusgoWeb.Mcp.Resources.TripApp

  @name "plan_trip"
  @text_length_max 200
  @modes ["now", "departAt", "arriveBy"]
  @days ["today", "tomorrow"]
  @clock ~r/\A(?:[01]\d|2[0-3]):[0-5]\d\z/

  @when_properties %{
    "mode" => %{
      "type" => "string",
      "enum" => @modes,
      "description" =>
        "now leaves at once, departAt leaves at the time, and arriveBy arrives by the time."
    },
    "day" => %{
      "type" => "string",
      "enum" => @days,
      "description" => "The day of the time. Today when absent."
    },
    "time" => %{
      "type" => "string",
      "pattern" => "^([01][0-9]|2[0-3]):[0-5][0-9]$",
      "description" =>
        "The time of day, 24-hour HH:MM on the rider's clock. Required unless mode is now."
    }
  }

  @doc "The name the tool is listed and called under."
  @spec name() :: String.t()
  def name, do: @name

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => @name,
      "title" => "Plan a trip",
      "description" =>
        "Plans a public transit trip in the Puget Sound region between two places the rider " <>
          "names, as they said them: a stop, a place, a street address, or an intersection " <>
          "such as \"Pine and 3rd\". The rider's device finds the places and the journeys " <>
          "and shows them to the rider, who chooses one; the chosen journey comes back as " <>
          "context. Pass the rider's words for each end unchanged. When the rider names no " <>
          ~s(start or says only "here", leave from out or pass "here": the app uses the ) <>
          "device's location where the host allows it and otherwise asks the rider where they are.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "from" => %{
            "type" => "string",
            "maxLength" => @text_length_max,
            "description" =>
              "Where the trip starts, in the rider's words for where they are: a street, a " <>
                "stop, or a place. Leave it out or pass \"here\" when the rider names no start."
          },
          "to" => %{
            "type" => "string",
            "maxLength" => @text_length_max,
            "description" => "Where the trip ends, in the rider's words."
          },
          "when" => %{
            "type" => "object",
            "properties" => @when_properties,
            "required" => ["mode"],
            "description" => "When the trip is for. Leaving now when absent."
          }
        },
        "required" => ["to"]
      },
      "_meta" => %{"ui" => %{"resourceUri" => TripApp.uri()}}
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema do
    {:map,
     %{
       "from" => {:optional, :string},
       "to" => :string,
       "when" =>
         {:optional,
          {:map,
           %{"mode" => :string, "day" => {:optional, :string}, "time" => {:optional, :string}}}}
     }}
  end

  @impl GobusgoWeb.Mcp.Tool
  def call(%{"to" => to} = arguments) do
    from = Map.get(arguments, "from")

    with :ok <- check_start(from),
         :ok <- check_end("to", to),
         :ok <- check_when(Map.get(arguments, "when")) do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => summary(from, to)}],
         "structuredContent" => Map.take(arguments, ["from", "to", "when"])
       }}
    end
  end

  defp summary(from, to) do
    case blank?(from) do
      true -> "Planning a trip to #{to}."
      false -> "Planning a trip from #{from} to #{to}."
    end
  end

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""

  defp check_start(nil), do: :ok

  defp check_start(text) do
    case String.length(text) > @text_length_max do
      true -> {:error, "from is longer than #{@text_length_max} characters."}
      false -> :ok
    end
  end

  defp check_end(field, text) do
    cond do
      String.trim(text) == "" ->
        {:error, "#{field} is blank. Pass the rider's words for it."}

      String.length(text) > @text_length_max ->
        {:error, "#{field} is longer than #{@text_length_max} characters."}

      true ->
        :ok
    end
  end

  defp check_when(nil), do: :ok

  defp check_when(%{"mode" => mode} = time) when mode in @modes do
    with :ok <- check_day(Map.get(time, "day")) do
      check_clock(mode, Map.get(time, "time"))
    end
  end

  defp check_when(%{"mode" => _mode}) do
    {:error, "when.mode is one of " <> Enum.join(@modes, ", ") <> "."}
  end

  defp check_day(nil), do: :ok
  defp check_day(day) when day in @days, do: :ok
  defp check_day(_day), do: {:error, "when.day is one of " <> Enum.join(@days, ", ") <> "."}

  defp check_clock("now", _time), do: :ok

  defp check_clock(_mode, time) when is_binary(time) do
    case Regex.match?(@clock, time) do
      true -> :ok
      false -> {:error, "when.time is a 24-hour time written HH:MM."}
    end
  end

  defp check_clock(_mode, nil), do: {:error, "when.time is required unless when.mode is now."}
end
