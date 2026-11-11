# Packed container

The packed container is the one binary form every published data file of a kind added after the routing snapshot uses: trip path shards (GOB-357), address shards (GOB-361), and places (GOB-366) each add a kind to it. The routing snapshot's own files keep their formats, which `lib/gobusgo/routing/AGENTS.md` holds (GOB-369). The Elixir core is `lib/gobusgo/packed.ex` with the submodules of `lib/gobusgo/packed/`, and the JavaScript core is `assets/js/packed_container.js`. Both are pure but for the browser's expansion of a stream, and neither knows the columns of a kind.

## Layout

Every number is little-endian. A file expanded is a 16-byte header and sections.

- **Header:** the magic `GBPK` in 4 ASCII bytes, a `u16` kind version, a `u16` kind, a `u32` record count, and a `u32` reserved, which is 0 and refused otherwise. The order matches the routing snapshot's header: magic, version, kind.
- **Sections:** each a `u32` byte length and that many bytes, one after another to the end of the file. The kind fixes how many sections follow the string table and what each holds. A file whose sections do not consume the bytes exactly, or that has another count than its reader's kind declares, is refused.
- **String table:** section 0 of every file. A `u32` count of entries, then each entry as an unsigned varint byte length and that many bytes of UTF-8; records refer to an entry by its index. Entries are unique, and the writer numbers them by first use (`Gobusgo.Packed.StringTable`), so one input order gives one table. A reader refuses an entry that is not valid UTF-8; the JavaScript reader checks each entry when it decodes the container, keeps byte offsets in `Uint32Array`s, and decodes an entry when `strings.at(index)` first asks for it, with no byte order mark stripped.
- **Varints:** unsigned LEB128, at most 5 bytes, value at most 2^32 - 1; a longer or larger one is `badVarint`. Zigzag is `2n` for `n >= 0` and `-2n - 1` otherwise, over `|n| <= 2^31 - 1`, so it fits a `u32`; a longitude delta between valid positions is at most 360,000,000, inside that. The JavaScript reader multiplies where a value can pass 2^31, never a 32-bit bitwise operator.
- **Fixed-width columns:** a section of one `u8`, `u16`, `u32`, or `i32` per record, read with a `DataView` at an offset. The reader checks the section is exactly `count * width` bytes (`badSectionSize`).
- **Positions:** two `i32` of microdegrees, `round(degrees * 1,000,000)`, latitude then longitude, and -2,147,483,648 on both axes for unknown. A latitude past ±90 degrees, a longitude past ±180, and an unknown on one axis alone are `badPosition`, as in the routing snapshot's positions file.
- **Position sequences, called paths:** a varint count of points, then per point the zigzag varint delta of latitude and of longitude from the point before it, the first from (0, 0). The JavaScript decoder returns one `Int32Array` of latitude and longitude in turn, never an object per point, and refuses a count the section cannot hold at two bytes a point before it allocates.

## Kinds

The table is `Gobusgo.Packed.Kinds`, the `KINDS` constant of `assets/js/packed_container.js`, and `test/fixtures/packed/kinds.json`, which an ExUnit test and `test/scripts/packed_container_check.mjs` each compare with their side. The table holds a kind's number, name, and file prefix, and no kind's columns: each kind's own change defines them. A kind added later takes the next free number in its own change.

| Number | Kind | Prefix | Defined by |
| --- | --- | --- | --- |
| 0 | fixture | `fixture` | this area's fixtures and tests, never published |
| 1 | trip path shard | `trip-paths` | GOB-357 |
| 2 | trip path index | `trip-paths-index` | GOB-357 |
| 3 | address shard | `addresses` | GOB-361, `lib/gobusgo/addresses/AGENTS.md` |
| 4 | address index | `addresses-index` | GOB-361, `lib/gobusgo/addresses/AGENTS.md` |
| 5 | places | `places` | GOB-366, `lib/gobusgo/places/AGENTS.md` |

## Versions

A kind's version is in the header. A change to a kind's columns raises that kind's version and writes a new fixture directory beside the old one, such as `core-v2`; readers name the versions they know and refuse any other as `unsupportedVersion`, a value and never a throw.

## Storing and serving

A container is stored as one gzip stream at `<directory>/<prefix>-<sha256>.bin.gz`, the SHA-256 being that of the gzip stream, the bytes a reader fetches. `Gobusgo.Packed.stored/1` returns the expanded `content`, which the writer is given and compresses itself, the `stream` it stores, and the stream's `byte_size` and `sha256`; the writer's compression gives the same stream for the same content, so the stream hashed is the one stored. Content past `Gobusgo.Compression.content_bytes_max/0` is an assertion failure at the writer. A file is cacheable for a year as immutable, because its name holds its hash. A set of files is named by a manifest, served `cache-control: no-cache` with an `etag`, whose entry for a file is `Gobusgo.Packed.file_entry/2`: `path`, `byteSize` of the stream, and `sha256`.

A reader expands under a bound. `Gobusgo.Packed.expand/2` returns `{:error, :too_large}` or `{:error, :corrupt}`, and `expandStream` in JavaScript returns `{kind: "refused", reason: "tooLarge" | "corrupt"}`, stopping to read once the bound is passed. The bound is the largest expanded size the kind's file may have, at most `CONTAINER_EXPANDED_BYTES_MAX`, which equals the server's content limit. The browser expands with `DecompressionStream`, decodes in place over one `DataView`, and asserts only on programmer errors.

## Elixir API

`Gobusgo.Packed.encode/1` takes `kind`, `version`, `record_count`, `strings`, and `sections` and returns the expanded bytes. `decode/2` takes the bytes and the reader's `kind`, `versions`, and `section_count`, each `:any` for the Mix task, and returns the header fields, the strings as a tuple, and the sections after the table, or `{:error, reason}`: `:bad_magic`, `:unknown_kind`, `:kind_mismatch`, `:unsupported_version`, `:reserved_not_zero`, `:truncated`, `:trailing_bytes`, `:section_count`, `:bad_varint`, `:bad_utf8`, `:bad_string_table`, `:bad_section_size`, `:bad_position`. `Gobusgo.Packed.Varint`, `Columns`, `Positions`, and `StringTable` hold the encoders and decoders of a section's contents, and `Gobusgo.Packed.Kind` is the optional behavior of a kind's module, whose `inspect/1` describes a decoded container.

## JavaScript API

`assets/js/packed_container.js` exports `expandStream(source, {expandedByteSizeMax})`, which returns `{kind: "expanded", bytes}` or `{kind: "refused", reason}`; `decodeContainer(bytes, {kind, versions, sectionCount})`, which returns `{kind: "decoded", header: {kind, version, recordCount}, strings: {count, at(index)}, sections: [{offset, byteLength}], view}` or a refusal with the reasons the Elixir decoder names in camel case; `openColumn({view, section, type, count})` and `openPositions({view, section, count})`, which return a reader or a refusal; and `SectionCursor`, whose `readVarint()` and `readPath()` read a section a varint or a path at a time and set `refusal` instead of throwing. The constants `KINDS`, `PackedKind`, `PackedOutcome`, `PackedRefusal`, `ColumnType`, `HEADER_BYTES`, `VARINT_VALUE_MAX`, `VARINT_BYTES_MAX`, `UNKNOWN_MICRODEGREES`, and `CONTAINER_EXPANDED_BYTES_MAX` name the format's numbers, and `unzigzag(value)` decodes a zigzag.

## Fixtures and checks

`test/fixtures/packed/core-v1/` holds `fixture.bin`, the fixture kind's container, `fixture.bin.gz`, the same bytes as one gzip stream, and `expected.json`, what a reader decodes. `test/scripts/packed_fixtures.exs` writes them from `Gobusgo.Test.PackedFixture` in `test/support/`; run it with `MIX_ENV=test mix run --no-start test/scripts/packed_fixtures.exs` after a change to the format or the records. ExUnit compares `fixture.bin` to the encoder's output byte for byte and `fixture.bin.gz` by its content, never its bytes, since a zlib release can change a stream's bytes. `node test/scripts/packed_container_check.mjs` decodes both files to `expected.json` and checks each refusal as a value: another kind, an unknown version, a bad magic, a non-zero reserved field, a cut file, trailing bytes, another section count, an over-long varint, invalid UTF-8, and an expanded size past the bound. The fixture holds a string table with ASCII, multibyte text, and an empty string, a string used twice, `u32`, `i32`, and `u16` columns, positions with a negative longitude, an unknown one, and both ends of the globe, paths with both delta signs, a long jump, one point, and none, and varints from 0 to 2^32 - 1.

## Mix task

`mix gobusgo.packed.decode <file> [--bytes-max N] [--kind-module Module]` reads a stored stream, a file named with the `.gz` ending, or an expanded file, expands the stream within `--bytes-max`, by default `Gobusgo.Compression.content_bytes_max/0`, decodes the header and string table for any kind and version, and prints JSON: the header, the strings, and per section its byte length and its base64 bytes. With `--kind-module`, a module that implements `Gobusgo.Packed.Kind`, it prints what that module's `inspect/1` returns instead. `Gobusgo.Places.Format` and `Gobusgo.Addresses.Format` are the kind modules so far (`lib/gobusgo/places/AGENTS.md`, `lib/gobusgo/addresses/AGENTS.md`). A refused file exits with the reason.
