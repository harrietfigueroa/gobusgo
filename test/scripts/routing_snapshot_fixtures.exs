# Writes the shared routing snapshot fixtures from the records of
# Gobusgo.Test.RoutingSnapshotFixture: one file of each kind, as
# Gobusgo.Routing.SnapshotFormat encodes it, and expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/routing_snapshot_fixtures.exs`
# after a change to the format or to the records.

alias Gobusgo.Routing.SnapshotFormat
alias Gobusgo.Test.RoutingSnapshotFixture

directory = RoutingSnapshotFixture.directory()

for {kind, records} <- RoutingSnapshotFixture.records() do
  File.write!(Path.join(directory, "#{kind}.bin"), SnapshotFormat.encode(kind, records))
end

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(RoutingSnapshotFixture.expected()) <> "\n"
)
