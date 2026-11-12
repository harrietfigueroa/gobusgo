# Places file

The places file is one published file of the names a rider searches for, such as a market, a hospital, a neighborhood, or a station, each with a position, built by hand from a Geofabrik Washington extract of OpenStreetMap and served as a packed container of kind 5 (GOB-353 decided it, GOB-366 builds it). Nothing in the application builds it or reads it on a start. This file holds the selection rules, the merge rules, the kind's layout, the fixtures, the manifest, serving, the Mix task, and the measurements.

## Files

- `classification.ex` holds the 14 categories in index order, the rules that put a tagged feature in one with the base prominence of each, `stop?/1`, and `tag_filters/0`, the `osmium tags-filter` expressions that select a superset of what `classify/1` accepts. Pure.
- `selection.ex` reads the records of an `osmium export` into candidates, with the counts of what became of each record. Pure.
- `words.ex` is the normalization a name is compared by, the same as the browser search's. Pure.
- `merge.ex` merges the candidates that name one place twice and orders what is left. Pure.
- `locality.ex` gives each merged place its locality from its address or the nearest settlement. Pure.
- `bounds.ex` parses `--bounds` and takes the union of the basemap manifest's archive bounds. Pure.
- `extractor.ex` runs `osmium` through `Gobusgo.Command` and splits the export into records. `plan/1` is the step arguments, pure.
- `build.ex` runs the extractor, selection, merge, and locality assignment, and removes the files it wrote.
- `records.ex` is the row of a place and the JSON that shows the rows. Pure.
- `format.ex` is the kind's encoder and decoder on `Gobusgo.Packed`, and implements `Gobusgo.Packed.Kind`. Pure.
- `license.ex` holds the texts of the file's license, its notice, and the manifest's `license` object. Pure.
- `publication.ex` stores the file, the notice, and the manifest through the writer.
- `lib/mix/tasks/gobusgo.places.build.ex` is the Mix task.
- `assets/js/place_file.js` is the browser's decoder, checked by `node test/scripts/place_file_check.mjs`.

## Selection

A feature is a candidate when it has a `name`, is not a stop or a platform, falls in a category, and has a position inside the bounds. The bounds are the union of the basemap manifest's archive bounds, or `--bounds`.

- **Stops and platforms are never places.** A feature tagged `highway=bus_stop`, `public_transport=platform`, `public_transport=stop_position`, `railway=platform`, `railway=tram_stop`, or `railway=stop` is left out before classification, whatever else it carries, such as `amenity=shelter` or `shop=kiosk`. Stops and platforms come from the stop view, not from OpenStreetMap, so the file holds none, and the summary counts them as `stops`. Stations stay: `railway=station|halt`, `public_transport=station`, `amenity=bus_station`, `amenity=ferry_terminal`, and `aeroway=aerodrome|terminal`.
- **Categories**, tested in this order, the first to match wins: station, hospital, health, education, park, leisure, tourism, food, amenity, shop, office, historic, building, place. The table of tags and bases is `classification.ex`, ported from the prototype of GOB-353. Street furniture and parking are left out by the lists of excluded `amenity`, `leisure`, and `tourism` values. A feature of no category is counted as excluded.
- **Position** is the point, or the area-weighted centroid of the outer rings of a polygon or multipolygon on a plane tangent at the first vertex, measured from each ring's own first vertex so large absolute meters lose no precision. The position is stored in integer microdegrees.
- **Name** has control characters and `;` replaced by spaces, is trimmed, and is cut to 200 characters. **Aliases** come from `alt_name`, `short_name`, `official_name`, `old_name`, `name:en`, and `loc_name`, each split on `;`, cleaned, distinct, and different from the name.
- **Prominence** is the category's base plus 40 for `wikidata` plus 15 for `wikipedia`, at most 255. **Area** is a separate score, 0 for a point or an area under 1,000 square meters, otherwise `min(40, round(8 * log10(area / 1000)))`. The file stores the two apart and never adds them.

## Merging

Two candidates of one normalized name (`words.ex`) are one place when they stand under 150 m apart, or under 300 m apart when either is a building: a park beside a building, or a building beside a station. Every other pair, a station and a park included, merges under 150 m only, so the "Seattle Center" park and the Monorail's station stay two places.

Candidates are taken in descending prominence plus area score, ties broken by name and then position, so the order does not depend on the input. The first of a group is kept, and it gains the aliases of the others. A park of prominence 135 and an area score of 20 therefore outlives a station of 140 with none. The places are then ordered by category, then name, which groups like text for compression.

## Locality

A place's locality is the text that tells two places of one name apart, shown in the "Where to?" suggestions between the category and the distance (GOB-404). `locality.ex` assigns it after the merge, so it is a property of the kept place:

- **A street address wins.** A feature tagged both `addr:housenumber` and `addr:street` has the locality "400 Broad Street", the two joined by a space, cleaned as a name is. A feature with one of them has no address.
- **Otherwise the nearest settlement names it.** The settlements are the features of category `place` tagged `place=neighbourhood`, `suburb`, `quarter`, `town`, or `city`, taken before the merge so a merge that keeps another feature of the same name loses none; a point or the centroid of an area. The nearest within 3,000 m (`@nearest_radius_m_max`), nearest first and then by name, names the place. A neighborhood, suburb, or quarter is followed by the nearest town or city within 20,000 m (`@city_radius_m_max`) when that city's name differs, as "Denny Triangle, Seattle"; a town or city stands alone.
- **A settlement never names itself.** A settlement skips an anchor of its own name, and a town or city has no locality, since the nearest other city is a neighbor.
- **Only the house number and street are read from `addr:*`.** `addr:city` and `addr:suburb` are tagged on a minority of features, so a city read from them would name some places and leave their neighbors bare; the settlements give every place a neighborhood and a city by one rule.
- **Bounded.** A locality is at most 80 characters (`Gobusgo.Places.Locality.length_max/0`, `LOCALITY_LENGTH_MAX` in `place_file.js`), cut at the build, refused by the encoder past it, and refused by both readers past it. A place with none has the empty string.
- **The search never matches on it.** The locality is shown, never indexed or ranked.

A cell grid over the settlements, 0.05 degrees for the nearest and 0.3 for the cities, keeps the assignment to the cells around a place. The inputs are the build's own: the settlements are features the places build already selects, so the file adds no data source, and the locality is OpenStreetMap data under the same ODbL.

## The kind

Kind 5, prefix `places`, version 2, one record per place, 9 sections after the string table:

1. names, a `u32` column of string indexes;
2. alias counts, a `u8` column, at most 255 a place, which the writer asserts;
3. alias names, one `u32` column of the string index of every alias in place order, as many as the counts sum to;
4. positions, the container's positions, none unknown, which the writer asserts;
5. categories, a `u8` column of indexes into the category names;
6. prominences, a `u8` column;
7. areas, a `u8` column;
8. labels, a `u32` column of string indexes: the source date first, then the category names in index order;
9. localities, a `u32` column of string indexes, the empty string for a place with none.

Version 1 holds the first 8 sections and no localities. `Gobusgo.Places.Format.decode/1` and `place_file.js` read both versions, and every place of a version 1 file has the empty locality, so a published version 1 file keeps working until the version 2 file is published. A reader of version 1 as it was before this version refuses a version 2 file as a value, the container's `unsupported_version`. The encoder writes version 2 only.

The string table interns the names, then the aliases, then the localities, then the labels, in order of first use, so a name two places share is stored once. `place_file.js` decodes a file into `{placeCount, names, aliasStarts, aliasNames, latitudeMicrodegrees, longitudeMicrodegrees, categories, prominences, areas, localities, categoryNames, sourceDate}`: `names`, `aliasNames`, `localities`, and `categoryNames` are arrays of strings, decoded eagerly, `aliasStarts` is a `Uint32Array` of `placeCount + 1` starts into `aliasNames`, and the rest are typed arrays. The decode of the real file measured 31 ms at 1x and 139 ms at 4x CPU throttle with eager strings, inside the prototype's 28 ms and 131 to 166 ms, so the reader keeps them eager.

A reader refuses a version it does not read, another section count for the file's version, a locality index past the string table, a locality past 80 characters (`bad_locality`, `badLocality`), alias counts that do not sum to the alias column, a category index past the categories, a name or alias index past the string table, a place with an unknown position, and labels that hold no category, each as a value (`PlaceFileRefusal` and the container's own reasons). A file expands to at most `Gobusgo.Places.Format.expanded_bytes_max/0`, 8 MiB, which `PLACE_FILE_EXPANDED_BYTES_MAX` repeats in JavaScript; the real file is 3.6 MB.

`mix gobusgo.packed.decode <file> --kind-module Gobusgo.Places.Format` prints a file as JSON.

## Fixtures

`test/fixtures/places/v2/` holds `places.bin`, `places.bin.gz`, `expected.json`, and `locality_over_bound.bin`, five hand-written places of `Gobusgo.Test.PlaceFixture` with ASCII and multibyte names, two places of one name, an alias list, no aliases, prominence and area at their caps, a negative longitude, the origin, a street address, a neighborhood with its city, and places with no locality; `locality_over_bound.bin` is the same file with a locality one character past the bound, which both readers refuse. `test/fixtures/places/v1/` keeps the version 1 files as a published file of that version, which both readers still decode. `test/scripts/place_fixtures.exs` writes the version 2 files: `MIX_ENV=test mix run --no-start test/scripts/place_fixtures.exs`. ExUnit compares `places.bin` to the encoder's output byte for byte and `places.bin.gz` by its content. A change to the kind's columns raises its version and writes a new directory beside the older ones. `test/fixtures/places/normalized_words.json` is the shared cases of the name normalization, which the browser search's tests use too.

## Publication

`Gobusgo.Places.Publication` stores the file at `places/places-<SHA-256 of the gzip stream>.bin.gz` through `Gobusgo.Writer` with a reader keep time of a year, then, only after the file is stored, `places/NOTICE.txt` and then `places/manifest.json`: canonical JSON with `file` (`path`, `byteSize`, and `sha256`, from `Gobusgo.Packed.file_entry/2`), `kind` (5), `kindVersion`, `license` (`name` "ODbL-1.0", `uri`, `attribution`, `attributionUri`, and `notice`, the notice's path), `sourceDate`, `placeCount`, and `builtAt`. The manifest and the notice change with a build, so the previous ones are deleted before the new ones are written and a reader that asks between the two finds no manifest; a file of the same name is left as it is.

`GobusgoWeb.Endpoint` serves `<GOBUSGO_DATA_DIR>/places` under `/places` with three `Plug.Static` plugs: the `places-` files as the gzip streams they are stored as, `application/gzip` with no content encoding, `public, max-age=31536000, immutable`, `manifest.json` with `no-cache` and an `etag`, and `NOTICE.txt` as `text/plain; charset=utf-8` with `no-cache` and an `etag`. With a bucket configured the files are in S3 and production needs a CloudFront behavior for `/places/*` from the bucket in the infrastructure repository, which does not exist yet.

Nothing deletes `places/`: `Gobusgo.RetentionPolicy` has no rule for it and the hourly cleanup leaves it alone, so an earlier file stays until it is removed by hand.

## License

The places file is a Derivative Database of OpenStreetMap, offered under the Open Database License 1.0 (ODbL), "© OpenStreetMap contributors" (GOB-367). `license.ex` holds the texts, pure, and the notice and the manifest's `license` object both read them. The file is not under the repository's own license. The ODbL's obligations and how each is met:

- **§4.2, notices.** `places/NOTICE.txt` names the file a Derivative Database of OpenStreetMap, offered under the ODbL with its address, credits "© OpenStreetMap contributors" with the copyright page, and names the manifest that names the whole database. `Gobusgo.Places.Publication` stores it before the manifest, and the manifest's `license` names it. The endpoint serves it at `/places/NOTICE.txt` as `text/plain; charset=utf-8` with `no-cache`. The Settings tab's licenses list "Places: ODbL 1.0, © OpenStreetMap contributors" with links to the ODbL, the copyright page, and the manifest.
- **§4.3, notice for a Produced Work.** A page that shows results from the file carries "Places © OpenStreetMap" linked to the copyright page. The Trip tab's "Where to?" list shows it under its suggestions while a place or an intersection is among them (`OSM_CREDIT` of `assets/js/where_to.js`, GOB-375).
- **§4.4, share alike.** The file is itself offered under the ODbL, whole and unrestricted, so the share-alike condition on a Derivative Database holds for it. Its notices stay in the file's notice and manifest.
- **§4.6, access.** `/places/manifest.json` is the stable, free address that names the current file. It needs no login, and the file it names is the whole database, in the container format `Gobusgo.Places.Format` describes and `mix gobusgo.packed.decode` reads.

OneBusAway's stop names stay outside the ODbL's share-alike beside the places file, as a Collective Database, on three conditions, which the OSM Foundation's guidelines state:

1. **No references between the two.** Neither dataset joins, deduplicates, filters, positions, or renames the other. A page may run both searches and show both result sets in one list, with OpenStreetMap credited (Geocoding Guideline).
2. **Each feature type comes from one source in the region.** Stops and platforms come only from OneBusAway, and the file excludes every feature tagged `highway=bus_stop`, `public_transport=platform`, `public_transport=stop_position`, `railway=platform`, `railway=tram_stop`, or `railway=stop` (`Classification.stop?/1`). Stations come only from OpenStreetMap, so a stop search never lists OneBusAway's parent stations (Horizontal Map Layers Guideline).
3. **No OneBusAway data in the places file and no OpenStreetMap data in the stop data.**

The Trip tab's search keeps them (GOB-375): `assets/js/where_to.js` puts each source's results in a group of its own and never joins, removes, renames, or moves one by another, and its stop search reads the routing snapshot's stops file, which holds only the stops a trip calls at and so no parent station. The offline bundle saves the places file whole, beside the stop data and apart from it.

Guidance, checked 2026-11-10:

- <https://opendatacommons.org/licenses/odbl/1-0/>
- <https://osmfoundation.org/wiki/Licence/Community_Guidelines/Collective_Database_Guideline_Guideline> (endorsed 2016-06-17)
- <https://osmfoundation.org/wiki/Licence/Community_Guidelines/Horizontal_Map_Layers_-_Guideline> (endorsed 2014-06-06)
- <https://osmfoundation.org/wiki/Licence/Community_Guidelines/Geocoding_-_Guideline> (endorsed 2017-08-24)
- <https://osmfoundation.org/wiki/Licence/Attribution_Guidelines>

## The task

`mix gobusgo.places.build --extract <path to .osm.pbf> [--bounds south,west,north,east] [--working-directory <dir>] [--records-json <path>]` runs five `osmium` commands through `Gobusgo.Command`, each with a 10-minute deadline, selects, merges, stores the file and the manifest, and prints the step times, the counts by category, and the stored paths. It never runs on a start.

1. `fileinfo -g header.option.osmosis_replication_timestamp` reads the source date, which must be a UTC date and time, and is refused when absent.
2. `extract -s smart -b <west,south,east,north>` cuts the bounds.
3. `tags-filter nwr/name` keeps what has a name.
4. `tags-filter` on `Classification.tag_filters/0` keeps what a category can accept.
5. `export -f geojsonseq -a type,id --geometry-types=point,polygon` writes the records, each after a U+001E separator because a tag value can hold a newline.

The intermediate files go to the working directory, which is a temporary one without the option, and are removed at the end. `--bounds` overrides the basemap manifest's; with neither the task refuses. `--records-json` also writes the rows of `Gobusgo.Places.Records` as JSON.

osmium is `osmium-tool` 1.19.1, installed with Homebrew (`brew install osmium-tool`) and found on the `PATH`, as tippecanoe is, since no mise backend publishes it. The tests run a stand-in. The extract step needs about 3 GB, which exceeds the container's limit, so the task is run on a developer machine.

## Measured

On 2026-11-10 on a development machine, from Geofabrik's Washington extract of 2026-11-08T21:21:00Z (366 MB) cut to the basemap archive's bounds, 46.888124 to 48.642845 north and -123.082727 to -121.533451 east:

- Read 118,433 features, 82,791 named, 163 stops, 5,170 excluded, 58 outside, 77,400 selected, 1,643 merged, **75,757 places**. By category: shop 17,990, building 12,029, food 11,319, amenity 9,185, office 6,632, park 3,975, health 3,357, tourism 3,108, leisure 2,721, place 2,284, education 1,940, historic 828, station 335, hospital 55.
- The file is 2,437,932 bytes expanded and 1,092,528 bytes gzipped, against the prototype's 2.6 MB and 1.06 MB.
- Steps: extract 5.7 to 8.4 s, `tags-filter` by name 2.1 to 2.3 s, by category 0.8 to 1.3 s, export 0.8 to 1.0 s, selection and merge 2.5 to 2.7 s. Peak resident memory of osmium: 3.08 GB for the extract (peak footprint 4.18 GB), 2.37 GB for each `tags-filter`, 95 MB for the export; the BEAM peaked at 270 MB.
- Headless Chrome against `mix phx.server`, nine runs each, medians: fetch 1.9 ms and expand 7.2 ms, decode 31 ms at 1x; fetch 5.0 ms, expand 29.5 ms, decode 139 ms at 4x CPU throttle. The JavaScript heap after a collection held 2.0 MB with the table and 0.6 MB without it.

On 2026-11-11 (GOB-404) the same extract, source date and bounds built version 2 with localities, into a scratch directory on a development machine, nothing published:

- The 75,757 places are the same. 41,797 have a street address as their locality, 20,548 a neighborhood with its city, 8,807 a settlement alone, and 4,605 none; 34,913 distinct localities, the longest at the 80-character bound.
- The file is 3,604,843 bytes expanded and 1,500,624 bytes gzipped, against version 1's 2,437,932 and 1,092,528: 1.17 MB and 408 KB more, inside the 8 MiB expansion bound.
- The steps took extract 3.6 s, `tags-filter` by name 1.1 s, by category 0.5 s, export 0.5 s, and selection and merge 2.3 s. The locality assignment runs after them and is not in those figures; the task finished in the same run with no step near its 10-minute deadline.
- `decodePlaceFile` in Node 24 took a median of 34.7 ms over nine runs on the expanded file. The headless Chrome figures above are version 1's and are not measured again for version 2.
