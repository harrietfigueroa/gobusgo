# Intersections

The intersection files are the published files of the crossings of named roads that a search of "4th & Pike", "Pine and 3rd", or "3rd Ave @ Pine St" reads in the browser, built by hand from a Geofabrik Washington extract of OpenStreetMap and published as packed containers of kinds 6 and 7 (GOB-364, decided by the measurements of GOB-354). Nothing in the application builds them or reads them on a start; the Trip tab's "Where to?" search reads them in the browser (GOB-375). This file holds the selection and merge rules, the kinds' layout, the fixtures, the manifest, serving, the Mix task, the license, and the measurements. The files are a separate set from the county address shards (`lib/gobusgo/addresses/AGENTS.md`), because they are a derivative database of OpenStreetMap and are published under its license, which the address files are not.

## Files

- `classification.ex` holds the `highway` classes of the roads, whether the build keeps `service` roads, and the `osmium tags-filter` expression of the classes. Pure.
- `opl.ex` reads the ways and nodes of osmium's OPL text format. Pure.
- `names.ex` turns a road's name into the key it is stored and searched by, through `Gobusgo.Addresses.Normalize`. Pure.
- `selection.ex` reads the export twice and returns the nodes that two differently named roads share, with the counts of what became of each way and node. It holds an ETS table for the length of the call.
- `merge.ex` makes intersections of the shared nodes. Pure. `streets.ex` stores each intersection under both of its streets. Pure.
- `extractor.ex` runs `osmium` through `Gobusgo.Command` and splits the export into lines. `plan/1` is the step arguments, pure.
- `build.ex` runs the extractor, selection, merge, and grouping, and removes the files it wrote. `select/1`, the part after osmium, is deterministic.
- `format.ex` is the encoder and decoder of the two kinds, shard and index, on `Gobusgo.Packed`, and implements `Gobusgo.Packed.Kind`. Pure.
- `publication.ex` cuts the shards with `Gobusgo.Addresses.Shards` and stores the files and the manifest through the writer.
- `lib/mix/tasks/gobusgo.intersections.build.ex` is the Mix task.
- `lib/gobusgo_web/controllers/intersection_manifest_controller.ex` serves the manifest.
- `assets/js/intersection_file.js` is the browser's decoder and `assets/js/intersection_lookup.js` the lookup that reads its tables, both checked by `node test/scripts/intersection_lookup_check.mjs`.

## Source and license

The source is OpenStreetMap through Geofabrik's Washington extract, `https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf`, which the places file reads too (`lib/gobusgo/places/AGENTS.md`): the date of its replication timestamp is the build's `sourceDate`.

OpenStreetMap's data is under the Open Database License 1.0, <https://opendatacommons.org/licenses/odbl/1-0/> — checked 2026-11-10. These files are a derivative database that the site makes public, so they are offered to everyone under the same license: the manifest names the license and the credit "© OpenStreetMap contributors", `GobusgoWeb.AppInfo.intersection_source/0` credits OpenStreetMap in the info panel's credits and says the files are offered under the ODbL, and the files are served from `/intersections/` for anyone to fetch. The county address shards hold no OpenStreetMap data and stay under the counties' terms.

## Selection

A way is a road when its `highway` is one of motorway, trunk, primary, secondary, tertiary, unclassified, residential, the five links, `living_street`, or `pedestrian`, and it has a `name` whose key is supported. The key of a name is the normalizer's street key (`Gobusgo.Intersections.Names`): a name whose key holds anything but upper case ASCII letters, digits, and single spaces is counted as `unsupported name` and left out, because the browser slices a key by character to choose its shard and a character outside that alphabet slices differently there than here wherever the two languages' case rules or character boundaries differ. A name of 200 characters or more is left out too.

A node is shared when ways of two different keys list it; two ways of one key, such as a street split in two, share nothing. A node with more than eight keys is counted as `crowded` and left out. A shared node outside the bounds is counted as `outside`. The bounds are the union of the basemap manifest's archive bounds (`Gobusgo.Places.Bounds`, the places file's), or `--bounds`.

### `service` roads are left out

`Gobusgo.Intersections.Classification.service_roads/0` is false. On 2026-11-10, from Geofabrik's extract of 2026-11-08T21:21:00Z cut to the basemap's bounds, keeping `highway=service` added 6,585 named ways and 4,244 shared nodes, and raised the intersections from 133,382 to 137,679, 4,297 or 3.2%, over 4,116 more pairs. Of the roughly 4,360 crossings that exist only with service roads, 2,277 involve a street that no road of another class carries. The `service` tag of those streets: 1,600 have none (many are real roads that mappers tagged `service`, such as "Command Post Rd" and "Switchboard Rd"), about 650 are alleys and driveways, and about 80 are parking aisles. 157 of the added crossings have a parking-lot word in a street name (parking, lot, garage, driveway, aisle, loading, ramp, and similar). A rider types the crossing of two public streets, and a crossing of an alley or a parking aisle with a street of the same name as a public one competes with it for the nearest match, so the service roads are dropped and the 3.2% they add is the cost. A choice of the `service` subtypes to keep is open; it needs no change to the format.

## Merging

Every pair of the keys through a node is a crossing at that node. The nodes of one pair within 150 m of the mean of a group are one intersection at the mean of their positions, so a dual carriageway or a roundabout that crosses a street at several nodes is one crossing. Nodes are taken in the order of their identifiers, so the result does not depend on the order of the export. Positions are integer microdegrees.

Each intersection is then stored under both streets' keys (`Gobusgo.Intersections.Streets`), a street's crossings ordered by position and then the other street's key, and the streets ordered by their shard key and then key, as the shard cutting needs them.

## The kinds

Both files are packed containers (`lib/gobusgo/packed/AGENTS.md`), version 1, written and read by `Gobusgo.Intersections.Format`. Kind 6, prefix `intersections`, is a shard; kind 7, prefix `intersections-index`, is the index. The header's record count is the count of streets in a shard and of shards in the index.

A shard holds one record per street key, in the order of the streets' shard keys, and 4 sections after the string table:

1. keys, a `u32` column of the string index of each street's key, such as `3RD AVE`;
2. counts, a `u32` column of the crossings of each street, at least one;
3. others, a `u32` column of the string index of the other street of every crossing, in street order, as many as the counts sum to;
4. positions: per street a path of the container, one point per crossing, latitude and longitude in microdegrees, each a zigzag varint difference from the point before it.

The index holds one record per shard, in the order of the prefixes, and 3 sections: prefixes, byte sizes, and digests of 32 bytes, as the address index holds them. The index holds no file names: a shard's file is in the index's directory, and `Gobusgo.Packed.file_name/1` and `packedFileName` in `assets/js/packed_container.js` name it from the kind and the digest, `intersections-<digest>.bin.gz`, so the digest is the one owner of the name. Both files' keys and shard prefixes are the address shards' (`Gobusgo.Addresses.Shards`): the shard of a street is chosen by the street's normalized name with its spaces removed, `3RD` for `3RD AVE`, and a prefix ending in `$` holds the streets named by the prefix alone.

`assets/js/intersection_file.js` decodes a shard into `{streetCount, strings, keys, crossingStarts, others, positions}` as typed arrays over a string table, and an index into `{shardCount, prefixes, paths, byteSizes, sha256s}`. Each of `loadIntersectionShard` and `loadIntersectionIndex` expands a gzip stream first and returns `{kind: "decoded", table}` or `{kind: "refused", reason}`, never a throw. A reader refuses another version, the other kind, another section count, a string index past the table, a crossing count of zero or counts that pass 32 bits, a column of another length, a path of another length than its street's crossings, bytes after the last path, a position outside the globe, and a digest section of another length. A shard and an index each expand to at most 1 MiB (`Gobusgo.Intersections.Format.expanded_bytes_max/1`; `INTERSECTION_SHARD_EXPANDED_BYTES_MAX` and `INTERSECTION_INDEX_EXPANDED_BYTES_MAX` repeat them in JavaScript).

`mix gobusgo.packed.decode <file> --kind-module Gobusgo.Intersections.Format` prints a shard or an index as JSON.

### Fixtures

`test/fixtures/intersections/v1/` holds `shard.bin`, `shard.bin.gz`, `index.bin`, `index.bin.gz`, and `expected.json`, written by `Gobusgo.Test.IntersectionFixture` with `MIX_ENV=test mix run --no-start test/scripts/intersection_fixtures.exs`. The shard holds the four streets of downtown Seattle's Pike, Pine, 3rd, and 4th, a street at the corners of the globe with a multibyte other street, and a street of one crossing; the index holds the empty prefix, a prefix a longer prefix extends, the `$` mark, a multibyte prefix, and a size at 32 bits. ExUnit compares each expanded file to the encoder's output byte for byte and each gzip file by its content, and `node test/scripts/intersection_lookup_check.mjs` decodes both forms to `expected.json`, checks each refusal, and runs the lookup over them. A change to a kind's columns raises its version and writes `v2/` beside `v1/`.

## The lookup

`assets/js/intersection_lookup.js` is pure and reads no network. `planIntersection({text, index})` parses the text with `parseQuery` of `address_normalize.js` and returns `{kind: "plan", query, prefix, path}` with the shard of the first street's name from the decoded index, `{kind: "notAnIntersection", reason}` for text that is not two streets around "&", "and", "at", "@", or "/", or `{kind: "noShard"}`. `searchIntersection({query, shard, near})` returns `{kind: "found", results}`, at most five, the crossing nearest `near` first, each `{label, lat, lon, distanceM, omittedPartCount}`, or `{kind: "missing"}`. A part the rider leaves out, a type or a direction, agrees with the street's; a part typed has to be equal, so "3rd St & Pike" finds nothing where the street is 3rd Ave. Every crossing is stored under both streets, so the shard of the first street typed answers either order. The Trip tab's search fetches the index once its box takes focus and a shard on the first text that names it, and keeps 16 decoded shards for the session (`assets/js/where_to_files.js`, GOB-375); the files are not saved for offline use.

## Publication

`Gobusgo.Intersections.Publication` cuts the streets into shards of at most 65,536 bytes before compression, the address shards' bound (`Gobusgo.Addresses.Build.shard_bytes_max/0`, which GOB-361 set for the transfer of a cold query on Slow 4G), stores each shard and the index as one gzip stream at `intersections/<prefix>-<SHA-256 of the stream>.bin.gz` through `Gobusgo.Writer` with a reader keep time of a year, then, only after every file is stored, the manifest at `intersections/manifest-<UTC build time>-<SHA-256 of the index>.json`: canonical JSON of the shape `components.schemas.IntersectionsManifest` describes in `priv/openapi.json`. The writer stores a destination once, so each build's manifest has a name of its own, and the reader takes the newest by name with `Gobusgo.Reader.discover/2` (`Publication.manifest/1`). The manifests of earlier builds are deleted only after the new one is stored, so a reader that asks at any moment finds one; a file of the same name is left as it is.

Nothing deletes `intersections/`: `Gobusgo.RetentionPolicy` has no rule for it, the hourly cleanup leaves it alone, and the bucket has no lifecycle rule for it, so the files of an earlier build stay until they are removed by hand.

## Serving

`GET /api/intersections/manifest` answers the manifest through `Gobusgo.Reader`, whatever backend stores it; its response is described by `components.schemas.IntersectionsManifest` in `priv/openapi.json`. `GobusgoWeb.Endpoint` serves `<GOBUSGO_DATA_DIR>/intersections` under `/intersections` with a `Plug.Static` for the files whose name starts with `intersections-`, answered as the gzip streams they are stored as, `application/gzip` with no content encoding, `public, max-age=31536000, immutable`. With a bucket configured the files are in S3, and production serves `/intersections/*` from the bucket through CloudFront and `/api/intersections/manifest` from the application (gobusgo-infra change #56).

## The task

`mix gobusgo.intersections.build --extract <path to .osm.pbf> [--bounds south,west,north,east] [--working-directory <dir>]` runs five `osmium` commands through `Gobusgo.Command`, each with a 10-minute deadline, selects, merges, stores the files and the manifest, and prints the step times, the counts, and the sizes of the files. It never runs on a start.

1. `fileinfo -g header.option.osmosis_replication_timestamp` reads the source date, which must be a UTC date and time, and is refused when absent.
2. `tags-filter` keeps the ways of the road classes with the nodes they list.
3. `tags-filter w/name` keeps the ways that have a name.
4. `extract -s complete_ways -b <west,south,east,north>` cuts the bounds.
5. `cat -f opl,add_metadata=false` writes the ways and nodes as text lines.

The roads are filtered before the cut, so the cut reads about 76 MB and not the 366 MB of the state. The intermediate files go to the working directory, which is a temporary one without the option, and are removed at the end. `--bounds` overrides the basemap manifest's; with neither the task refuses. osmium is `osmium-tool` 1.19.1, installed with Homebrew (`brew install osmium-tool`) and found on the `PATH`, as for the places file. The tests run a stand-in, and the pure selection is tested over a hand-written export (`Gobusgo.Test.IntersectionOpl`).

## Measured

On 2026-11-10 on a development machine, from Geofabrik's Washington extract of 2026-11-08T21:21:00Z, the newest it had published, cut to the basemap manifest's bounds, 46.888124 to 48.642846 north and -123.082727 to -121.533451 east:

- 163,772 ways read and 163,751 kept (21 with an unsupported name), 1,402,536 road nodes, 126,824 shared, 2 crowded, 40 outside the bounds, 131,180 pairs, **133,382 intersections** on **40,202 streets**.
- **556 shards**, gzip at a median of 4,424 bytes, a 90th percentile of 14,403, and a maximum of 34,255, 3,261,973 bytes in all; before compression a median of 8,094, a 90th percentile of 26,053, and a maximum of 64,172 against the bound of 65,536, 5,878,206 in all. The index is 21,932 bytes compressed. The bound of 131,072 that this build used before GOB-361 lowered the address bound gave 173 shards, a gzip maximum of 67,456, and an index of 15,311 bytes with the file names in it; GOB-354's JSON prototype made 529 shards of 2.92 MB with `service` roads.
- The steps: `roads` 1.8 s, `names` 0.7 s, `extract` 0.8 s, `export` 0.1 s, selection, merge, and grouping 6.7 s, 14 s in all. The Mix task peaked at a maximum resident size of 334 MB (`/usr/bin/time -l`), under the start-memory check's 700 MiB threshold, and a peak footprint of 394 MB; the build never runs in the application.
- Against GOB-354's table with Seattle's center as the point: "4th & Pike" finds `4TH AVE & PIKE ST` at 47.610214, -122.336737 first of 2 in a shard of 17,128 bytes, and "Pine and 3rd" finds `PINE ST & 3RD AVE` at 47.610745, -122.338721 first of 4 in a shard of 16,960 bytes, as the table has them, in under 5 ms each in Node. Both shards were under the bound already and are the same files as before.

Per-county counts are not measured: the build holds no county boundaries.
