defmodule GobusgoWeb.Mcp.Tools.Alerts do
  @route_field "route"
  @stop_field "stop"
  @seconds_per_minute 60

  @moduledoc """
  The `alerts` tool: the current and upcoming service alerts that name the
  given routes or stops, as the vehicle page's alert panel reads them
  (`GobusgoWeb.ServiceAlerts`) from the situation views. The tool starts no
  fetch.

  The call needs at least one of `#{@route_field}` and `#{@stop_field}`,
  each a list judged by `Gobusgo.Filter`. An alert is kept when it affects
  any of the routes or any of the stops; one that names an agency and no
  route or stop is left out, as on a page. The views hold the alerts of the
  running trips and of the open stops, so the answer is bounded by what
  they hold.

  `data.alerts` lists the current alerts newest first, then the upcoming
  ones soonest first, at most `GobusgoWeb.Mcp.Answer.item_count_max/0`, and
  `meta.restCount` counts the rest. `meta.fetchedAt` and `meta.requestId`
  name the oldest situation fetch, so every alert is at least that fresh.

  A held answer is keyed on the situation fetches and the minute, since an
  alert's window opens and closes with the clock.
  """

  @behaviour GobusgoWeb.Mcp.Tool

  alias Gobusgo.Filter
  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.Mcp.AnswerCache
  alias GobusgoWeb.TransitQuery

  @unavailable "No alert data is available yet. Ask again in a few seconds."

  @impl GobusgoWeb.Mcp.Tool
  def definition do
    %{
      "name" => "alerts",
      "title" => "Service alerts for routes and stops",
      "description" =>
        Answer.description(
          "Lists the current and upcoming service alerts that name the given routes or " <>
            "stops, current ones first, at most #{Answer.item_count_max()}; give at least one " <>
            "of route and stop. Find identifiers with the find tool. The alerts are those " <>
            "of the running trips and the open stops: a route with nothing running, or a " <>
            "stop no page or arrivals call holds, can have an alert this tool does not " <>
            "know. An alert that names only an agency is left out."
        ),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          @route_field =>
            id_list("Route identifiers; an alert that affects any of them is kept."),
          @stop_field => id_list("Stop identifiers; an alert that affects any of them is kept.")
        },
        "additionalProperties" => false
      },
      "outputSchema" => Answer.output_schema(data_schema())
    }
  end

  @impl GobusgoWeb.Mcp.Tool
  def arguments_schema do
    {:map,
     %{
       @route_field => {:optional, {:list, :string}},
       @stop_field => {:optional, {:list, :string}}
     }}
  end

  @impl GobusgoWeb.Mcp.Tool
  def call(arguments) do
    raw = Map.take(arguments, [@route_field, @stop_field])
    spec = %{@route_field => :string, @stop_field => :string}

    case Filter.normalize(%{raw: raw, spec: spec}) do
      {:ok, filter} when map_size(filter) == 0 -> {:error, empty_refusal()}
      {:ok, filter} -> answer(filter)
      {:error, violations} -> {:error, refusal(violations)}
    end
  end

  defp answer(filter) do
    now_minute = Integer.floor_div(System.system_time(:second), @seconds_per_minute)
    key = {:alerts, filter, TransitQuery.alerts_version(), now_minute}

    outcome =
      AnswerCache.fetch(key, fn ->
        shape(
          TransitQuery.alerts(%{
            route_ids: Map.get(filter, @route_field, []),
            stop_ids: Map.get(filter, @stop_field, [])
          })
        )
      end)

    case outcome do
      :unavailable -> {:error, @unavailable}
      {:ok, answer} -> Answer.result(answer)
    end
  end

  defp shape(:unavailable), do: :unavailable

  defp shape({:ok, %{fetch: fetch, alerts: alerts}}) do
    kept = Enum.take(alerts, Answer.item_count_max())
    extra = %{"restCount" => length(alerts) - length(kept)}

    {:ok,
     %{
       "data" => %{"alerts" => Enum.map(kept, &alert/1)},
       "meta" => Answer.meta(%{fetch: fetch, count: length(kept), extra: extra})
     }}
  end

  defp alert(%{situation: situation, status: status, starts_at: starts_at}) do
    %{
      "id" => situation.id,
      "status" => Atom.to_string(status),
      "summary" => situation.summary,
      "description" => situation.description,
      "url" => situation.url,
      "startsAt" => starts_at(starts_at),
      "activeWindows" => Enum.map(situation.active_windows, &window/1),
      "routeIds" => affected_ids(situation, :route_id),
      "stopIds" => affected_ids(situation, :stop_id)
    }
  end

  defp starts_at(nil), do: nil
  defp starts_at(%DateTime{} = starts_at), do: Answer.iso(starts_at)

  defp window(%{from_ms: from_ms, to_ms: to_ms}), do: %{"fromMs" => from_ms, "toMs" => to_ms}

  defp affected_ids(situation, field) do
    ids = for affect <- situation.affects, id = Map.fetch!(affect, field), id != nil, do: id
    ids |> Enum.uniq() |> Enum.sort()
  end

  defp empty_refusal do
    "Give at least one route or stop (fields #{@route_field} and #{@stop_field}); " <>
      "neither has a value."
  end

  # A violation names the field and the reason and never the value.
  defp refusal(violations) do
    reasons =
      Enum.map_join(violations, "; ", fn %{field: field, reason: reason} ->
        "#{field || "filter"}: #{reason}"
      end)

    "The route and stop lists are not valid (" <>
      reasons <>
      "). At most " <>
      "#{Filter.value_count_max()} values of #{Filter.value_bytes_max()} bytes each."
  end

  defp id_list(description) do
    %{
      "type" => "array",
      "items" => %{"type" => "string", "maxLength" => Filter.value_bytes_max()},
      "maxItems" => Filter.value_count_max(),
      "description" => description
    }
  end

  defp data_schema do
    nullable_string = %{"type" => ["string", "null"]}
    nullable_integer = %{"type" => ["integer", "null"]}
    string_list = %{"type" => "array", "items" => %{"type" => "string"}}

    %{
      "type" => "object",
      "properties" => %{
        "alerts" => %{
          "type" => "array",
          "maxItems" => Answer.item_count_max(),
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "status" => %{"enum" => ["current", "upcoming"]},
              "summary" => %{"type" => "string"},
              "description" => nullable_string,
              "url" => nullable_string,
              "startsAt" => %{"type" => ["string", "null"], "format" => "date-time"},
              "activeWindows" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{"fromMs" => nullable_integer, "toMs" => nullable_integer},
                  "required" => ["fromMs", "toMs"]
                }
              },
              "routeIds" => string_list,
              "stopIds" => string_list
            },
            "required" => [
              "id",
              "status",
              "summary",
              "startsAt",
              "activeWindows",
              "routeIds",
              "stopIds"
            ]
          }
        }
      },
      "required" => ["alerts"]
    }
  end
end
