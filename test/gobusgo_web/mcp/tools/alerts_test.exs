defmodule GobusgoWeb.Mcp.Tools.AlertsTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, over the application's global views, which
  # the test fills with Gobusgo.Test.TransitSeeds, hence the non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Tools.Alerts

  @day_ms 24 * 60 * 60 * 1_000

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)

    :ok =
      TransitSeeds.vehicle_situations("1", [
        situation(%{id: "1_detour", affects: [affect("1_100", nil)]}),
        situation(%{
          id: "1_stop",
          summary: "Stop closed",
          affects: [affect("1_100", "1_55")]
        }),
        situation(%{id: "1_agency", affects: [%{agency_id: "1", route_id: nil, stop_id: nil}]})
      ])
  end

  defp situation(overrides) do
    Map.merge(
      %{
        id: "1_detour",
        summary: "Detour",
        description: "Use the stop on 4th Ave.",
        url: "https://example.test/detour",
        reason: "CONSTRUCTION",
        creation_time_ms: System.os_time(:millisecond) - @day_ms,
        active_windows: [],
        affects: []
      },
      overrides
    )
  end

  defp affect(route_id, stop_id), do: %{agency_id: "1", route_id: route_id, stop_id: stop_id}

  defp alerts(arguments) do
    {:ok, %{"structuredContent" => structured} = result} = Alerts.call(arguments)
    {result, structured}
  end

  defp alert_ids(%{"data" => %{"alerts" => alerts}}), do: Enum.map(alerts, & &1["id"])

  describe "call/1" do
    test "answers the alerts that name a route" do
      {_result, answer} = alerts(%{"route" => ["1_100"]})

      assert alert_ids(answer) == Enum.sort(["1_detour", "1_stop"])
    end

    test "answers the alerts that name a stop" do
      {_result, answer} = alerts(%{"stop" => ["1_55"]})

      assert alert_ids(answer) == ["1_stop"]
    end

    test "answers the alerts of a stop from the arrival situations" do
      :ok =
        TransitSeeds.arrival_situations("1_77", [
          situation(%{id: "1_arrival", affects: [affect("1_9", "1_77")]})
        ])

      {_result, answer} = alerts(%{"stop" => ["1_77"]})

      assert alert_ids(answer) == ["1_arrival"]
    end

    test "answers an empty list for a route with no alert" do
      {_result, %{"data" => data, "meta" => meta}} = alerts(%{"route" => ["1_999"]})

      assert data == %{"alerts" => []}
      assert %{"count" => 0, "restCount" => 0} = meta
      assert is_binary(meta["fetchedAt"])
    end

    test "leaves out an alert that names an agency and no route" do
      {_result, answer} = alerts(%{"route" => ["1_100"], "stop" => ["1_55"]})

      refute "1_agency" in alert_ids(answer)
    end

    test "gives an alert what the source gave it" do
      starts_ms = System.os_time(:millisecond) + @day_ms
      window = %{from_ms: starts_ms, to_ms: starts_ms + @day_ms}

      :ok =
        TransitSeeds.vehicle_situations("1", [
          situation(%{
            id: "1_later",
            affects: [affect("1_100", "1_55"), affect("1_100", "1_56")],
            active_windows: [window]
          })
        ])

      {_result, %{"data" => %{"alerts" => [alert]}}} = alerts(%{"route" => ["1_100"]})

      assert %{
               "id" => "1_later",
               "status" => "upcoming",
               "summary" => "Detour",
               "description" => "Use the stop on 4th Ave.",
               "url" => "https://example.test/detour",
               "routeIds" => ["1_100"],
               "stopIds" => ["1_55", "1_56"],
               "activeWindows" => [%{"fromMs" => from_ms, "toMs" => to_ms}]
             } = alert

      assert {from_ms, to_ms} == {starts_ms, starts_ms + @day_ms}
      assert is_binary(alert["startsAt"])
    end

    test "marks a current alert and gives it no start" do
      {_result, %{"data" => %{"alerts" => [alert | _rest]}}} = alerts(%{"stop" => ["1_55"]})

      assert %{"status" => "current", "startsAt" => nil, "activeWindows" => []} = alert
    end

    test "holds at most the bound of alerts and counts the rest" do
      many =
        for number <- 1..120, do: situation(%{id: "1_#{number}", affects: [affect("1_100", nil)]})

      :ok = TransitSeeds.vehicle_situations("1", many)

      {_result, %{"data" => %{"alerts" => kept}, "meta" => meta}} =
        alerts(%{"route" => ["1_100"]})

      assert length(kept) == 100
      assert %{"count" => 100, "restCount" => 20} = meta
    end

    test "carries the same answer as structured content and as text" do
      {result, structured} = alerts(%{"route" => ["1_100"]})

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "gives a newer fetch's answer once it arrives" do
      {_before, before} = alerts(%{"route" => ["1_100"]})

      :ok =
        TransitSeeds.vehicle_situations("1", [
          situation(%{id: "1_new", affects: [affect("1_100", nil)]})
        ])

      {_after, answer} = alerts(%{"route" => ["1_100"]})

      assert alert_ids(before) == Enum.sort(["1_detour", "1_stop"])
      assert alert_ids(answer) == ["1_new"]
    end

    test "answers an error to be acted on while the situation views hold no fetch" do
      TransitSeeds.restart_views()

      assert {:error, text} = Alerts.call(%{"route" => ["1_100"]})
      assert text =~ "No alert data is available yet"
    end

    test "refuses a call with neither route nor stop, naming both fields" do
      assert {:error, text} = Alerts.call(%{})

      assert text =~ "route"
      assert text =~ "stop"
    end

    test "refuses a call whose lists are blank" do
      assert {:error, text} = Alerts.call(%{"route" => [""], "stop" => []})

      assert text =~ "route"
    end

    test "refuses a list the contract refuses, naming the field and no value" do
      too_many = for number <- 1..51, do: "secret-#{number}"

      assert {:error, text} = Alerts.call(%{"stop" => too_many})

      assert text =~ "stop: too_many_values"
      refute text =~ "secret"
    end

    test "refuses a value longer than the contract allows" do
      assert {:error, text} = Alerts.call(%{"route" => [String.duplicate("x", 129)]})

      assert text =~ "route: value_too_long"
    end
  end

  describe "arguments_schema/0" do
    test "accepts each field alone or together" do
      schema = Alerts.arguments_schema()

      assert Schema.mismatch(%{"route" => ["1_100"]}, schema) == nil
      assert Schema.mismatch(%{"stop" => ["1_55"]}, schema) == nil
      assert Schema.mismatch(%{"route" => ["1_100"], "stop" => ["1_55"]}, schema) == nil
    end

    test "refuses a field that is not a list of text" do
      schema = Alerts.arguments_schema()

      assert %{path: ["route"]} = Schema.mismatch(%{"route" => "1_100"}, schema)
      assert %{path: ["stop", 0]} = Schema.mismatch(%{"stop" => [1]}, schema)
    end
  end

  describe "definition/0" do
    test "names the terms, credits the data as provided as is, and says what the alerts cover" do
      %{"description" => description} = Alerts.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
      assert description =~ "running trips"
      assert description =~ "open stops"
    end

    test "takes route and stop and no other field" do
      assert %{"inputSchema" => %{"properties" => properties, "additionalProperties" => false}} =
               Alerts.definition()

      assert Map.keys(properties) == ["route", "stop"]
    end

    test "has an output schema" do
      assert %{"outputSchema" => %{"properties" => %{"data" => _data}}} = Alerts.definition()
    end
  end
end
