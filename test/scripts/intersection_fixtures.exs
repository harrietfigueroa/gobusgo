# Writes the shared intersection fixtures of Gobusgo.Test.IntersectionFixture:
# the expanded containers of a shard and an index, each also as one gzip
# stream, and expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/intersection_fixtures.exs`
# after a change to the intersection kinds or to the records. A change to a
# kind's columns raises its version and writes a new fixture directory.

alias Gobusgo.Test.IntersectionFixture

directory = IntersectionFixture.directory()
File.mkdir_p!(directory)

for {name, expanded} <- [
      shard: IntersectionFixture.encode_shard(),
      index: IntersectionFixture.encode_index()
    ] do
  File.write!(Path.join(directory, "#{name}.bin"), expanded)
  File.write!(Path.join(directory, "#{name}.bin.gz"), Gobusgo.Compression.compress(expanded))
end

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(IntersectionFixture.expected()) <> "\n"
)
