defmodule GobusgoWeb.Mcp.Tools.VehiclesTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, over the application's global views, which
  # the test fills with Gobusgo.Test.TransitSeeds, hence the non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Tools.Vehicles
  alias GobusgoWeb.TransitQuery

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)

    :ok = TransitSeeds.vehicles("1", [{"1_a", "1_100"}, {"1_b", "1_200"}, {"1_c", nil}])
    :ok = TransitSeeds.vehicles("40", [{"40_x", "40_500"}])
  end

  defp vehicles(arguments) do
    {:ok, %{"structuredContent" => structured} = result} = Vehicles.call(arguments)
    {result, structured}
  end

  defp vehicle_ids(%{"data" => %{"vehicles" => vehicles}}),
    do: Enum.map(vehicles, & &1["vehicleId"])

  describe "call/1" do
    test "answers every vehicle under no filter, in agency order" do
      {_result, answer} = vehicles(%{})

      assert vehicle_ids(answer) == ["1_a", "1_b", "1_c", "40_x"]
    end

    test "answers the markers the page shows for the same filter" do
      filter = %{"agency" => ["1"], "route" => ["1_100", "1_200"]}
      {_result, answer} = vehicles(filter)

      assert {:ok, %{markers: markers}} = TransitQuery.vehicles(filter)

      assert vehicle_ids(answer) ==
               Enum.map(markers, fn {_agency_id, marker} -> marker.vehicle_id end)

      assert vehicle_ids(answer) == ["1_a", "1_b"]
    end

    test "applies agencies and routes together and the values of one field as alternatives" do
      {_result, answer} = vehicles(%{"agency" => ["1", "40"], "route" => ["1_100", "40_500"]})

      assert vehicle_ids(answer) == ["1_a", "40_x"]
    end

    test "keeps no vehicle without a route under a filter that names a route" do
      {_result, answer} = vehicles(%{"route" => ["1_100"]})

      refute "1_c" in vehicle_ids(answer)
    end

    test "gives a vehicle the texts and fields the map shows" do
      {_result, %{"data" => %{"vehicles" => [vehicle | _rest]}}} = vehicles(%{"agency" => ["1"]})

      assert %{
               "id" => _id,
               "agencyId" => "1",
               "vehicleId" => "1_a",
               "lat" => 47.66,
               "lon" => -122.34,
               "routeId" => "1_100",
               "status" => "reported",
               "locationAge" => _location_age,
               "realTime" => _real_time
             } = vehicle
    end

    test "names the oldest fetch in meta and each fetch beside it" do
      {_result, %{"meta" => meta}} = vehicles(%{})

      assert %{"fetchedAt" => fetched_at, "requestId" => request_id, "count" => 4} = meta
      assert [%{"agencyId" => "1"} = first, %{"agencyId" => "40"}] = meta["fetches"]
      assert first["fetchedAt"] == fetched_at
      assert first["requestId"] == request_id
      assert meta["restCount"] == 0
    end

    test "answers no vehicle and no fetch for a filter that keeps no agency with a fetch" do
      {_result, %{"data" => data, "meta" => meta}} = vehicles(%{"agency" => ["95"]})

      assert data == %{"vehicles" => []}
      assert %{"fetchedAt" => nil, "requestId" => nil, "count" => 0, "fetches" => []} = meta
    end

    test "carries the same answer as structured content and as text" do
      {result, structured} = vehicles(%{"agency" => ["40"]})

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "holds at most the bound of vehicles and counts the rest" do
      fleet = for number <- 1..120, do: {"95_#{number}", nil}
      :ok = TransitSeeds.vehicles("95", fleet)

      {_result, %{"data" => %{"vehicles" => kept}, "meta" => meta}} =
        vehicles(%{"agency" => ["95"]})

      assert length(kept) == 100
      assert %{"count" => 100, "restCount" => 20} = meta
    end

    test "gives the same answer to a call between fetches" do
      {_first, first} = vehicles(%{"agency" => ["1"]})
      {_second, second} = vehicles(%{"agency" => ["1"]})

      assert first == second
    end

    test "gives a newer fetch's answer once it arrives" do
      {_before, before} = vehicles(%{"agency" => ["1"]})
      :ok = TransitSeeds.vehicles("1", [{"1_z", nil}])

      {_after, answer} = vehicles(%{"agency" => ["1"]})

      assert vehicle_ids(before) == ["1_a", "1_b", "1_c"]
      assert vehicle_ids(answer) == ["1_z"]
    end

    test "answers an error to be acted on while the vehicle view holds no fetch" do
      TransitSeeds.restart_views()

      assert {:error, text} = Vehicles.call(%{})
      assert text =~ "No vehicle data is available yet"
    end

    test "refuses a filter the contract refuses, naming the field and no value" do
      too_many = for number <- 1..51, do: "secret-#{number}"

      assert {:error, text} = Vehicles.call(%{"agency" => too_many})

      assert text =~ "agency: too_many_values"
      refute text =~ "secret"
    end

    test "refuses a value longer than the contract allows" do
      assert {:error, text} = Vehicles.call(%{"route" => [String.duplicate("x", 129)]})

      assert text =~ "route: value_too_long"
    end
  end

  describe "arguments_schema/0" do
    test "accepts no filter, and each field alone or together" do
      schema = Vehicles.arguments_schema()

      assert Schema.mismatch(%{}, schema) == nil
      assert Schema.mismatch(%{"agency" => ["1"]}, schema) == nil
      assert Schema.mismatch(%{"agency" => ["1"], "route" => ["1_100"]}, schema) == nil
    end

    test "refuses a field that is not a list of text" do
      schema = Vehicles.arguments_schema()

      assert %{path: ["agency"]} = Schema.mismatch(%{"agency" => "1"}, schema)
      assert %{path: ["route", 0]} = Schema.mismatch(%{"route" => [1]}, schema)
    end
  end

  describe "definition/0" do
    test "names the terms and credits the data as provided as is" do
      %{"description" => description} = Vehicles.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
    end

    test "takes the fields of the filter contract and no other" do
      assert %{"inputSchema" => %{"properties" => properties, "additionalProperties" => false}} =
               Vehicles.definition()

      assert Map.keys(properties) == ["agency", "route"]
    end
  end
end
