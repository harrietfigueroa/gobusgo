# Writes the shared trip path fixtures of Gobusgo.Test.TripPathShardFixture:
# the loop route's shard and an index, each as expanded bytes and as one gzip
# stream, and expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/trip_path_fixtures.exs`
# after a change to the format of a kind or to the records. A change to the
# format of a kind raises its version and writes a new fixture directory.

alias Gobusgo.Compression
alias Gobusgo.Test.TripPathShardFixture

directory = TripPathShardFixture.directory()
File.mkdir_p!(directory)

shard = TripPathShardFixture.shard_content()
File.write!(Path.join(directory, "shard.bin"), shard)
File.write!(Path.join(directory, "shard.bin.gz"), Compression.compress(shard))

index = TripPathShardFixture.index_content()
File.write!(Path.join(directory, "index.bin"), index)
File.write!(Path.join(directory, "index.bin.gz"), Compression.compress(index))

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(TripPathShardFixture.expected()) <> "\n"
)
