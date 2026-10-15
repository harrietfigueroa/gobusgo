defmodule Gobusgo.OneBusAway.Situations do
  @situation_count_max 200
  @summary_length_max 1_000
  @description_length_max 10_000
  @affect_count_max 500
  @active_window_count_max 50

  @moduledoc """
  The service alerts of one OneBusAway response, which the source calls
  situations: those `data.references.situations` holds. Everything here is
  pure.

  OneBusAway has no method of its own for situations. A response references
  the situations of what it lists: a `vehicles-for-agency` response those of
  the trips its vehicles serve, and an `arrivals-and-departures-for-stop`
  response also those of a route at the stop.

  A situation that breaks a rule below is rejected alone and counted, so a
  response's other situations, and everything else it holds, are kept.

    * Its identifier is a non-empty string that no earlier situation of the
      response holds.
    * Its summary is a string with a character other than white space, of
      at most #{@summary_length_max} characters, and its description, when
      present, of at most #{@description_length_max}.
    * It has at most #{@active_window_count_max} active windows, each start
      no later than its end, and at most #{@affect_count_max} affects.
    * A response holds at most #{@situation_count_max} situations; those
      beyond are rejected.

  The texts are kept as the source sends them, line breaks included, except
  the link, which is trimmed and kept only when it is an `http` or `https`
  address with a host. A window start or end the source sends as zero or
  leaves out is `nil`: an active window with no start began before any
  time a page shows, and one with no end lasts until the agency withdraws
  the situation, as GTFS-realtime's `active_period` reads (unverified
  against OneBusAway, GOB-223). A situation with no active window is active
  for as long as it is published. An affect that names no agency, route,
  or stop is left out; trips and directions are not read.
  """

  alias Gobusgo.Schema

  @typedoc "When a situation applies, in milliseconds since the Unix epoch."
  @type active_window :: %{from_ms: integer() | nil, to_ms: integer() | nil}

  @typedoc "What a situation applies to: a stop is named only with a route at it."
  @type affect :: %{
          agency_id: String.t() | nil,
          route_id: String.t() | nil,
          stop_id: String.t() | nil
        }

  @type t :: %{
          id: String.t(),
          summary: String.t(),
          description: String.t() | nil,
          url: String.t() | nil,
          reason: String.t() | nil,
          creation_time_ms: integer() | nil,
          active_windows: [active_window()],
          affects: [affect()]
        }

  @type parsed :: %{situations: [t()], rejected_count: non_neg_integer()}

  @text_schema {:nullable, {:map, %{"value" => :string}}}

  @source_schema {:map,
                  %{
                    "id" => :string,
                    "summary" => {:map, %{"value" => :string}},
                    "description" => {:optional, @text_schema},
                    "url" => {:optional, @text_schema},
                    "reason" => {:optional, {:nullable, :string}},
                    "creationTime" => {:optional, {:nullable, :integer}},
                    "activeWindows" =>
                      {:optional,
                       {:list,
                        {:map,
                         %{
                           "from" => {:optional, {:nullable, :integer}},
                           "to" => {:optional, {:nullable, :integer}}
                         }}}},
                    "allAffects" =>
                      {:optional,
                       {:list,
                        {:map,
                         %{
                           "agencyId" => {:optional, {:nullable, :string}},
                           "routeId" => {:optional, {:nullable, :string}},
                           "stopId" => {:optional, {:nullable, :string}}
                         }}}}
                  }}

  @data_schema {:map,
                %{
                  "id" => :string,
                  "summary" => :string,
                  "description" => {:nullable, :string},
                  "url" => {:nullable, :string},
                  "reason" => {:nullable, :string},
                  "creationTimeMs" => {:nullable, :integer},
                  "activeWindows" =>
                    {:list,
                     {:map, %{"fromMs" => {:nullable, :integer}, "toMs" => {:nullable, :integer}}}},
                  "affects" =>
                    {:list,
                     {:map,
                      %{
                        "agencyId" => {:nullable, :string},
                        "routeId" => {:nullable, :string},
                        "stopId" => {:nullable, :string}
                      }}}
                }}

  @doc "The most situations one response holds."
  @spec situation_count_max() :: pos_integer()
  def situation_count_max, do: @situation_count_max

  @doc "The schema of a situation in a published record, as `to_data/1` writes it."
  @spec data_schema() :: Schema.t()
  def data_schema, do: @data_schema

  @doc """
  Returns the situations that `data`, the `data` of a response envelope,
  references, in the source's order, with the count of those rejected.
  """
  @spec parse(map()) :: parsed()
  def parse(data) when is_map(data) do
    case get_in(data, [Access.key("references", %{}), Access.key("situations", [])]) do
      sources when is_list(sources) -> parse_sources(sources)
      _other -> %{situations: [], rejected_count: 1}
    end
  end

  defp parse_sources(sources) do
    {taken, beyond} = Enum.split(sources, @situation_count_max)

    {situations, _ids} =
      Enum.reduce(taken, {[], MapSet.new()}, fn source, {situations, ids} ->
        case situation(source) do
          {:ok, %{id: id} = situation} ->
            if MapSet.member?(ids, id) do
              {situations, ids}
            else
              {[situation | situations], MapSet.put(ids, id)}
            end

          :rejected ->
            {situations, ids}
        end
      end)

    situations = Enum.reverse(situations)
    %{situations: situations, rejected_count: length(taken) - length(situations) + length(beyond)}
  end

  defp situation(source) do
    with nil <- Schema.mismatch(source, @source_schema),
         %{"id" => id, "summary" => %{"value" => summary}} = source,
         true <- id != "",
         true <- within_length?(summary, @summary_length_max),
         true <- String.trim(summary) != "",
         description = text(source["description"]),
         true <- description == nil or within_length?(description, @description_length_max),
         windows = Map.get(source, "activeWindows", []),
         affects = Map.get(source, "allAffects", []),
         true <- length(windows) <= @active_window_count_max,
         true <- length(affects) <= @affect_count_max,
         active_windows = Enum.map(windows, &active_window/1),
         true <- Enum.all?(active_windows, &ordered?/1) do
      {:ok,
       %{
         id: id,
         summary: summary,
         description: description,
         url: url(text(source["url"])),
         reason: present(source["reason"]),
         creation_time_ms: source["creationTime"],
         active_windows: active_windows,
         affects: affects |> Enum.map(&affect/1) |> Enum.reject(&empty_affect?/1)
       }}
    else
      _rejected -> :rejected
    end
  end

  defp within_length?(text, length_max), do: String.length(text) <= length_max

  defp text(%{"value" => value}), do: present(value)
  defp text(nil), do: nil

  defp present(""), do: nil
  defp present(value), do: value

  defp active_window(window) do
    %{from_ms: time_ms(window["from"]), to_ms: time_ms(window["to"])}
  end

  defp time_ms(0), do: nil
  defp time_ms(time_ms), do: time_ms

  defp ordered?(%{from_ms: from_ms, to_ms: to_ms})
       when is_integer(from_ms) and is_integer(to_ms) do
    from_ms <= to_ms
  end

  defp ordered?(_open_window), do: true

  defp affect(source) do
    %{
      agency_id: present(source["agencyId"]),
      route_id: present(source["routeId"]),
      stop_id: present(source["stopId"])
    }
  end

  defp empty_affect?(affect), do: affect == %{agency_id: nil, route_id: nil, stop_id: nil}

  # The source pads some links with white space.
  defp url(nil), do: nil

  defp url(value) do
    trimmed = String.trim(value)

    case URI.new(trimmed) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        trimmed

      _other ->
        nil
    end
  end

  @doc "Returns `situation` as a published record holds it, in camel case."
  @spec to_data(t()) :: map()
  def to_data(situation) do
    %{
      "id" => situation.id,
      "summary" => situation.summary,
      "description" => situation.description,
      "url" => situation.url,
      "reason" => situation.reason,
      "creationTimeMs" => situation.creation_time_ms,
      "activeWindows" =>
        Enum.map(situation.active_windows, &%{"fromMs" => &1.from_ms, "toMs" => &1.to_ms}),
      "affects" =>
        Enum.map(
          situation.affects,
          &%{"agencyId" => &1.agency_id, "routeId" => &1.route_id, "stopId" => &1.stop_id}
        )
    }
  end

  @doc """
  Returns the situation `data` holds, a value that matches `data_schema/0`
  as `to_data/1` writes it.
  """
  @spec from_data(map()) :: t()
  def from_data(data) do
    %{
      id: data["id"],
      summary: data["summary"],
      description: data["description"],
      url: data["url"],
      reason: data["reason"],
      creation_time_ms: data["creationTimeMs"],
      active_windows:
        Enum.map(data["activeWindows"], &%{from_ms: &1["fromMs"], to_ms: &1["toMs"]}),
      affects:
        Enum.map(
          data["affects"],
          &%{agency_id: &1["agencyId"], route_id: &1["routeId"], stop_id: &1["stopId"]}
        )
    }
  end
end
