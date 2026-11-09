# Writes the shared routing snapshot fixtures from the records of
# Gobusgo.Test.RoutingSnapshotFixture: one file of each kind, as
# Gobusgo.Routing.SnapshotFormat encodes it, and expected.json; and the
# names fixture of Gobusgo.Test.RoutingNamesFixture, the names file as one
# gzip stream and its expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/routing_snapshot_fixtures.exs`
# after a change to a format or to the records.

alias Gobusgo.Routing.SnapshotFormat
alias Gobusgo.Test.RoutingNamesFixture
alias Gobusgo.Test.RoutingSnapshotFixture

directory = RoutingSnapshotFixture.directory()

for {kind, records} <- RoutingSnapshotFixture.records() do
  File.write!(Path.join(directory, "#{kind}.bin"), SnapshotFormat.encode(kind, records))
end

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(RoutingSnapshotFixture.expected()) <> "\n"
)

names_directory = RoutingNamesFixture.directory()
File.mkdir_p!(names_directory)

File.write!(
  Path.join(names_directory, "names.json.gz"),
  Gobusgo.Compression.compress(RoutingNamesFixture.content())
)

File.write!(
  Path.join(names_directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(RoutingNamesFixture.expected()) <> "\n"
)
