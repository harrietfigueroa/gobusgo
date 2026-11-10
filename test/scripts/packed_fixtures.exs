# Writes the shared packed container fixture of Gobusgo.Test.PackedFixture:
# the expanded container, the same bytes as one gzip stream, and
# expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/packed_fixtures.exs`
# after a change to the container format or to the records. A change to the
# format of a kind raises its version and writes a new fixture directory.

alias Gobusgo.Test.PackedFixture

directory = PackedFixture.directory()
File.mkdir_p!(directory)

expanded = PackedFixture.encode()
File.write!(Path.join(directory, "fixture.bin"), expanded)
File.write!(Path.join(directory, "fixture.bin.gz"), Gobusgo.Compression.compress(expanded))

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(PackedFixture.expected()) <> "\n"
)
