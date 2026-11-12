# Writes the shared places fixture of Gobusgo.Test.PlaceFixture: the expanded
# container, the same bytes as one gzip stream, and expected.json. Run it with
# `MIX_ENV=test mix run --no-start test/scripts/place_fixtures.exs` after a
# change to the places kind or to the records. A change to the kind's columns
# raises its version and writes a new fixture directory.

alias Gobusgo.Test.PlaceFixture

directory = PlaceFixture.directory()
File.mkdir_p!(directory)

expanded = PlaceFixture.encode()
File.write!(Path.join(directory, "places.bin"), expanded)
File.write!(Path.join(directory, "places.bin.gz"), Gobusgo.Compression.compress(expanded))

File.write!(
  Path.join(directory, "locality_over_bound.bin"),
  PlaceFixture.encode_locality_over_bound()
)

File.write!(
  Path.join(directory, "expected.json"),
  Gobusgo.CanonicalJson.encode(PlaceFixture.expected()) <> "\n"
)
