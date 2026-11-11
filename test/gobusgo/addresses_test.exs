defmodule Gobusgo.AddressesTest do
  # Calls the pure rules of the schedule and the manifest's destination, and
  # drives check/1 against a process over a temporary directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses
  alias Gobusgo.Test.AddressSource
  alias Gobusgo.Test.AddressSourceTwo

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defp built_on(nil), do: :none

  defp built_on(date) do
    {:ok,
     %{inputs_sha256: <<0::256>>, built_at: DateTime.new!(date, ~T[12:00:00]), built_on: date}}
  end

  describe "due?/1" do
    for {name, built_date, now, expected} <- [
          {"with no build, at any time", nil, ~U[2026-11-10 00:30:00Z], true},
          {"with a build of today", ~D[2026-11-10], ~U[2026-11-10 23:00:00Z], false},
          {"with a build of yesterday before the slot", ~D[2026-11-09], ~U[2026-11-10 09:59:59Z],
           false},
          {"with a build of yesterday at the slot", ~D[2026-11-09], ~U[2026-11-10 10:00:00Z],
           true},
          {"with a build of last week after the slot", ~D[2026-11-03], ~U[2026-11-10 15:00:00Z],
           true}
        ] do
      test "is #{expected} #{name}" do
        check = %{
          built: built_on(unquote(Macro.escape(built_date))),
          now: unquote(Macro.escape(now))
        }

        assert Addresses.due?(check) == unquote(expected)
      end
    end
  end

  describe "manifest_destination/1" do
    test "holds the directory, the county, the build time, and the hash of the input, so a county's names sort by build" do
      earlier =
        Addresses.manifest_destination(%{
          directory: "addresses/dt=2026-11-10",
          county: :pierce,
          built_at: ~U[2026-11-10 09:00:00Z],
          inputs_sha256: <<1::256>>
        })

      later =
        Addresses.manifest_destination(%{
          directory: "addresses/dt=2026-11-10",
          county: :pierce,
          built_at: ~U[2026-11-10 10:00:00Z],
          inputs_sha256: <<0::256>>
        })

      assert earlier ==
               "addresses/dt=2026-11-10/manifest-pierce-20261110T0900000Z-0000000000000000000000000000000000000000000000000000000000000001.json"

      assert earlier < later
      assert Addresses.manifest_county(earlier) == {:ok, "pierce"}
    end

    test "a manifest named before builds had counties is King County's" do
      legacy =
        "addresses/dt=2026-11-11/manifest-20261111T1000000Z-0000000000000000000000000000000000000000000000000000000000000001.json"

      assert Addresses.manifest_county(legacy) == {:ok, "king"}
    end

    test "names no file that is not a manifest" do
      assert Addresses.manifest_county("addresses/dt=2026-11-10/shard-ab.bin.gz") == :none
    end
  end

  describe "spec/1" do
    test "is a scheduler spec that passes the scheduler's own check" do
      spec = Addresses.spec(server: Addresses)

      assert spec.name == Gobusgo.AddressScheduler
      assert spec.cadence.policy == {:fixed, 3_600_000}
      assert spec.deadline_ms < 3_600_000
    end

    test "gives each county a deadline of its own, under the scheduler's" do
      spec = Addresses.spec(server: Addresses)

      for {source, _options} <- Gobusgo.Addresses.Build.sources() do
        assert source.run_deadline_ms() < spec.deadline_ms
      end
    end
  end

  describe "check/1" do
    setup %{tmp_dir: tmp_dir, line: line} do
      server = Module.concat(__MODULE__, "Addresses#{line}")
      start_supervised!({Addresses, name: server, read_options: [base_dir: tmp_dir]})
      %{server: server}
    end

    defp main_street(city) do
      %{
        house_number: "1",
        pre_direction: "",
        name: "MAIN",
        type: "ST",
        suf_direction: "",
        city: city,
        lat: 47.3,
        lon: -122.2
      }
    end

    # Two counties, `:test` then `:test_two`; `second` replaces the options
    # of the second.
    defp options(context, now, second \\ [records: [main_street("EVERETT")]]) do
      [
        server: context.server,
        sources: [
          {AddressSource, [records: [main_street("KENT")]]},
          {AddressSourceTwo, second}
        ],
        bounds: :none,
        clock: fn -> now end,
        write_options: [base_dir: context.tmp_dir]
      ]
    end

    defp counties(server) do
      {:ok, %{"counties" => counties}} = Addresses.manifest(server)
      Enum.map(counties, & &1["county"])
    end

    test "builds at once when no build is stored, whatever the time", context do
      assert Addresses.check(options(context, ~U[2026-11-10 00:30:00Z])) ==
               {:ok, %{outcome: :built, county: :test}}

      assert counties(context.server) == ["test"]
    end

    test "builds one county a check, the next due one in the order of the sources", context do
      now = ~U[2026-11-10 12:00:00Z]
      Addresses.check(options(context, now))

      assert Addresses.check(options(context, now)) ==
               {:ok, %{outcome: :built, county: :test_two}}

      assert counties(context.server) == ["test", "test_two"]
      assert Addresses.check(options(context, now)) == {:ok, %{outcome: :not_due}}
    end

    test "a county that fails leaves the county built before it current", context do
      now = ~U[2026-11-10 12:00:00Z]
      failing = [answer: {:error, {:transport, :timeout}}]
      Addresses.check(options(context, now, failing))

      assert Addresses.check(options(context, now, failing)) ==
               {:error, {:fetch, :test_two, {:transport, :timeout}}}

      assert counties(context.server) == ["test"]
    end

    test "a start finds the newest build of each county, a manifest named before counties as King's",
         context do
      now = ~U[2026-11-10 12:00:00Z]
      Addresses.check(options(context, now))
      Addresses.check(options(context, now))

      legacy_path =
        Path.join(
          context.tmp_dir,
          "addresses/dt=2026-11-09/manifest-20261109T1000000Z-#{String.duplicate("ab", 32)}.json"
        )

      File.mkdir_p!(Path.dirname(legacy_path))

      File.write!(
        legacy_path,
        JSON.encode!(%{
          "builtAt" => "2026-11-09T10:00:00Z",
          "inputsSha256" => String.duplicate("ab", 32),
          "index" => %{"path" => "/addresses/dt=2026-11-09/addresses-index-x.bin.gz"},
          "shards" => []
        })
      )

      restarted = Module.concat(__MODULE__, "Restarted#{context.line}")

      start_supervised!(
        {Addresses, name: restarted, read_options: [base_dir: context.tmp_dir]},
        id: :restarted
      )

      assert counties(restarted) == ["king", "test", "test_two"]
      assert {:ok, %{built_on: ~D[2026-11-09]}} = Addresses.built(restarted, :king)
      assert {:ok, %{built_on: ~D[2026-11-10]}} = Addresses.built(restarted, :test_two)
    end

    test "builds nothing before the slot of a later day", context do
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))

      assert Addresses.check(options(context, ~U[2026-11-11 09:00:00Z])) ==
               {:ok, %{outcome: :not_due}}
    end

    test "builds again at the slot of a later day", context do
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))

      assert Addresses.check(options(context, ~U[2026-11-11 10:00:00Z])) ==
               {:ok, %{outcome: :built, county: :test}}
    end
  end
end
