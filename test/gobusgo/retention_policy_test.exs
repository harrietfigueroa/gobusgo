defmodule Gobusgo.RetentionPolicyTest do
  # Verifies the retention table and the cleanup's spec: the days each
  # dataset is kept, that no rule reaches into another's dataset, and that
  # the spec runs the cleanup under those rules. The run goes through the
  # file backends under the test's temporary directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Cadence
  alias Gobusgo.Deleter
  alias Gobusgo.Reader
  alias Gobusgo.Retention
  alias Gobusgo.RetentionPolicy
  alias Gobusgo.Scheduler
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  defp day_count(prefix) do
    [%{day_count: day_count}] = Enum.filter(RetentionPolicy.rules(), &(&1.prefix == prefix))
    day_count
  end

  describe "rules/0" do
    for {prefix, day_count} <- [
          {"raw/oba/vehicles-for-agency", 1},
          {"raw/oba/arrivals-and-departures-for-stop", 1},
          {"raw/oba/agencies-with-coverage", 30},
          {"raw/oba/routes-for-agency", 30},
          {"raw/oba/stops-for-route", 30},
          {"raw/oba/schedule-for-route", 3},
          {"usage/page-connections", 3},
          {"tiles/route-stops", 2},
          {"routing/snapshots", 2}
        ] do
      test "keeps #{prefix} for #{day_count} days" do
        assert day_count(unquote(prefix)) == unquote(day_count)
      end
    end

    test "holds nine rules, each one Retention accepts" do
      rules = RetentionPolicy.rules()

      assert length(rules) == 9
      assert Enum.all?(rules, &(Retention.assert_rule(&1) == :ok))
    end

    test "has no rule whose dataset lies inside another's" do
      withins = Enum.map(RetentionPolicy.rules(), &Retention.within/1)

      for within <- withins, other <- withins, within != other do
        refute String.starts_with?(within, other)
      end
    end
  end

  describe "usage_day_count/0" do
    test "is the days of the usage rule" do
      assert RetentionPolicy.usage_day_count() == day_count("usage/page-connections")
    end
  end

  describe "cleanup_spec/1" do
    test "is a spec a scheduler accepts, run once an hour" do
      spec = RetentionPolicy.cleanup_spec([])

      assert Scheduler.assert_spec(spec) == :ok
      assert spec.name == Gobusgo.CleanupScheduler
      assert Cadence.interval_ms(spec.cadence.policy, spec.cadence.signals.()) == 3_600_000
    end

    test "runs the cleanup under the rules", %{tmp_dir: base_dir} do
      expired = "usage/page-connections/dt=2026-10-01/a.json.gz"
      kept = "usage/page-connections/dt=2026-10-07/b.json.gz"

      for destination <- [expired, kept] do
        :ok =
          Writer.write(%{destination: destination, content: "content"},
            backend: Writer.LocalFile,
            base_dir: base_dir
          )
      end

      spec =
        RetentionPolicy.cleanup_spec(
          today: ~D[2026-10-08],
          read_options: [backend: Reader.LocalFile, base_dir: base_dir],
          delete_options: [backend: Deleter.LocalFile, base_dir: base_dir]
        )

      assert {:ok, %{deleted_count: 1, failed_count: 0}} = spec.run.()

      assert {:ok, %{destinations: [^kept]}} =
               Reader.discover(%{prefix: "usage/", limit: 10, order: :ascending, cursor: nil},
                 backend: Reader.LocalFile,
                 base_dir: base_dir
               )
    end
  end
end
