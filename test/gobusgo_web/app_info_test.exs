defmodule GobusgoWeb.AppInfoTest do
  # Verifies the texts of the info panel as pure functions of the cadences
  # they are given, and checks the license entries against the two files
  # that own those facts: the lock file of the vendored packages and the
  # repository's license.
  use ExUnit.Case, async: true

  alias GobusgoWeb.AppInfo

  @lock_path "assets/vendor.lock.json"
  @license_path "LICENSE"
  @cadences %{vehicle_interval_ms: 5_000, route_period_minutes: 1_440}

  defp data_use_text(cadences), do: cadences |> AppInfo.data_use() |> Enum.join(" ")

  describe "about/0" do
    test "says what the map shows" do
      assert AppInfo.about() =~ "Puget Sound"
    end
  end

  describe "data_use/1" do
    for {vehicle_interval_ms, text} <- [
          {1_000, "every second"},
          {5_000, "every 5 seconds"},
          {60_000, "every 60 seconds"}
        ] do
      test "says vehicles are read #{text} for an interval of #{vehicle_interval_ms} ms" do
        cadences = %{@cadences | vehicle_interval_ms: unquote(vehicle_interval_ms)}

        assert data_use_text(cadences) =~ "read #{unquote(text)}"
      end
    end

    for {route_period_minutes, text} <- [
          {60, "every hour"},
          {720, "every 12 hours"},
          {1_440, "once a day"}
        ] do
      test "says routes and stops are read #{text} for a period of #{route_period_minutes} minutes" do
        cadences = %{@cadences | route_period_minutes: unquote(route_period_minutes)}

        assert data_use_text(cadences) =~ "read #{unquote(text)}"
      end
    end

    test "names the source" do
      assert data_use_text(@cadences) =~ "OneBusAway"
    end

    for {label, cadences} <- [
          {"a vehicle interval that is no whole count of seconds",
           %{vehicle_interval_ms: 1_500, route_period_minutes: 1_440}},
          {"a vehicle interval of zero", %{vehicle_interval_ms: 0, route_period_minutes: 1_440}},
          {"a route period that is no whole count of hours",
           %{vehicle_interval_ms: 5_000, route_period_minutes: 90}},
          {"a route period of zero", %{vehicle_interval_ms: 5_000, route_period_minutes: 0}}
        ] do
      test "refuses #{label}" do
        assert_raise Gobusgo.Assert.AssertionError, fn ->
          AppInfo.data_use(unquote(Macro.escape(cadences)))
        end
      end
    end
  end

  describe "disclaimer/0" do
    test "says the app is independent and that no agency endorses it" do
      disclaimer = AppInfo.disclaimer()

      assert disclaimer =~ "independent project"
      assert disclaimer =~ "not endorsed by"
      assert disclaimer =~ "transit agencies"
    end
  end

  describe "terms/0" do
    test "names the terms the data is provided under, at an https address" do
      assert %{name: "Transit Data Terms of Use", url: "https://www.soundtransit.org/" <> _path} =
               AppInfo.terms()
    end
  end

  describe "app_license/0" do
    test "states the license and the copyright line of the repository's license" do
      %{name: name, copyright: copyright} = AppInfo.app_license()
      [first_line | rest] = @license_path |> File.read!() |> String.split("\n")

      assert first_line == name
      assert copyright in rest
    end
  end

  describe "components/0" do
    test "names a license for every vendored package and archive" do
      lock = @lock_path |> File.read!() |> JSON.decode!()
      locked_names = for entry <- lock["packages"] ++ lock["archives"], do: entry["name"]

      named = Enum.flat_map(AppInfo.components(), & &1.lock_names)

      assert Enum.sort(named) == Enum.sort(locked_names)
    end

    test "gives every component a name and a license" do
      for component <- AppInfo.components() do
        assert %{name: <<_, _::binary>>, license: <<_, _::binary>>} = component
      end
    end
  end
end
