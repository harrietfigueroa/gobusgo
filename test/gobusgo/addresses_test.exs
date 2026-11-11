defmodule Gobusgo.AddressesTest do
  # Calls the pure rules of the schedule and the manifest's destination, and
  # drives check/1 against a process over a temporary directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses
  alias Gobusgo.Test.AddressSource

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
    test "holds the directory, the build time, and the hash of the input, so names sort by build" do
      earlier =
        Addresses.manifest_destination(%{
          directory: "addresses/dt=2026-11-10",
          built_at: ~U[2026-11-10 09:00:00Z],
          inputs_sha256: <<1::256>>
        })

      later =
        Addresses.manifest_destination(%{
          directory: "addresses/dt=2026-11-10",
          built_at: ~U[2026-11-10 10:00:00Z],
          inputs_sha256: <<0::256>>
        })

      assert earlier ==
               "addresses/dt=2026-11-10/manifest-20261110T0900000Z-0000000000000000000000000000000000000000000000000000000000000001.json"

      assert earlier < later
      assert Addresses.manifest_destination?(earlier)
    end

    test "names no file that is not a manifest" do
      refute Addresses.manifest_destination?("addresses/dt=2026-11-10/shard-ab.bin.gz")
    end
  end

  describe "spec/1" do
    test "is a scheduler spec that passes the scheduler's own check" do
      spec = Addresses.spec(server: Addresses)

      assert spec.name == Gobusgo.AddressScheduler
      assert spec.cadence.policy == {:fixed, 3_600_000}
      assert spec.deadline_ms < 3_600_000
    end
  end

  describe "check/1" do
    setup %{tmp_dir: tmp_dir, line: line} do
      server = Module.concat(__MODULE__, "Addresses#{line}")
      start_supervised!({Addresses, name: server, read_options: [base_dir: tmp_dir]})
      %{server: server}
    end

    defp options(context, now) do
      [
        server: context.server,
        sources: [
          {AddressSource,
           [
             records: [
               %{
                 house_number: "1",
                 pre_direction: "",
                 name: "MAIN",
                 type: "ST",
                 suf_direction: "",
                 city: "KENT",
                 lat: 47.3,
                 lon: -122.2
               }
             ]
           ]}
        ],
        bounds: :none,
        clock: fn -> now end,
        write_options: [base_dir: context.tmp_dir],
        work_directory: Path.join(context.tmp_dir, "work")
      ]
    end

    test "builds at once when no build is stored, whatever the time", context do
      assert Addresses.check(options(context, ~U[2026-11-10 00:30:00Z])) ==
               {:ok, %{outcome: :built}}

      assert {:ok, _manifest} = Addresses.manifest(context.server)
    end

    test "builds nothing before the slot of a later day", context do
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))

      assert Addresses.check(options(context, ~U[2026-11-11 09:00:00Z])) ==
               {:ok, %{outcome: :not_due}}
    end

    test "builds again at the slot of a later day", context do
      Addresses.check(options(context, ~U[2026-11-10 12:00:00Z]))

      assert Addresses.check(options(context, ~U[2026-11-11 10:00:00Z])) ==
               {:ok, %{outcome: :built}}
    end
  end
end
