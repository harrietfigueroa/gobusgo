# Writes the shared walk graph fixtures of Gobusgo.Test.WalkGraphFixture: the
# expanded containers of two shards and an index, each also as one gzip
# stream, and expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/walk_graph_fixtures.exs`
# after a change to the walk graph kinds or to the records. A change to a
# kind's columns raises its version and writes a new fixture directory.

alias Gobusgo.Test.WalkGraphFixture

directory = WalkGraphFixture.directory()
File.mkdir_p!(directory)

for {name, expanded} <- [
      {"shard-west", WalkGraphFixture.encode_shard(:west)},
      {"shard-east", WalkGraphFixture.encode_shard(:east)},
      {"index", WalkGraphFixture.encode_index()}
    ] do
  File.write!(Path.join(directory, "#{name}.bin"), expanded)
  File.write!(Path.join(directory, "#{name}.bin.gz"), Gobusgo.Compression.compress(expanded))
end

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(WalkGraphFixture.expected()) <> "\n"
)
