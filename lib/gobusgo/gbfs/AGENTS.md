# GBFS integration

The General Bikeshare Feed Specification (GBFS) is the open format in which shared bike and scooter operators publish where their vehicles are. Gobusgo reads it through one generic client, so any operator that publishes a feed is read the same way; today the one system it serves is Lime Seattle, the only operator Seattle's free-floating micromobility permit names (GOB-254). The client reads three files: the discovery file `gbfs.json`, the vehicle file (`free_bike_status` in 1.0 and 2.2, `vehicle_status` in 3.0), and `vehicle_types` (2.2 and 3.0). `Gobusgo.Gbfs.VehicleTypesCycle` fetches the vehicle types once a day (GOB-257), as the "Vehicle types" section below holds, and `Gobusgo.Gbfs.VehicleStatusCycle` fetches the vehicles while a page shows them (GOB-256), as the "Shared vehicles" section holds.

## Documentation sources

All links checked 2026-11-08.

- GBFS 3.0: <https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md>
- GBFS 2.2: <https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md>
- GBFS 1.0: <https://github.com/MobilityData/gbfs/blob/v1.0/gbfs.md>
- Files and their 404 rule: <https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#files>
- Field types, timestamps among them: <https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#field-types> and <https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md#field-types>
- `vehicle_status`, with the identifier rotation rule: <https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#vehicle_statusjson>
- `free_bike_status` in 2.2: <https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md#free_bike_statusjson>
- `free_bike_status` in 1.0: <https://github.com/MobilityData/gbfs/blob/v1.0/gbfs.md#free_bike_statusjson>
- `vehicle_types` in 3.0: <https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#vehicle_typesjson>
- `vehicle_types` in 2.2, with its form factors: <https://github.com/MobilityData/gbfs/blob/v2.2/gbfs.md#vehicle_typesjson-added-in-v21>
- The catalog of published systems, where Lime Seattle is `lime_seattle`: <https://github.com/MobilityData/gbfs/blob/master/systems.csv>
- Lime's Public GBFS Terms: <https://www.li.me/legal/public-gbfs-terms>

## Lime Seattle

The discovery file of each version, all answering 200 on 2026-11-08:

- 3.0: <https://data.lime.bike/api/partners/v3/gbfs/seattle/gbfs.json>
- 2.2: <https://data.lime.bike/api/partners/v2/gbfs/seattle/gbfs.json>
- 1.0: <https://data.lime.bike/api/partners/v1/gbfs/seattle/gbfs.json>

The 3.0 manifest, <https://data.lime.bike/api/partners/v3/manifest.json>, lists 2.2 and 3.0 for `lime_seattle`; the 1.0 feed is published without a manifest entry, and no version publishes `gbfs_versions.json`. Each discovery file lists `system_information`, `station_information`, `station_status`, and the vehicle file, and 2.2 and 3.0 also list `vehicle_types`. The station files hold one placeholder station named "Seattle". Lime publishes no `geofencing_zones` and no `system_pricing_plans` in any version: both answer 404 under 3.0, and no discovery file lists them. The permit sends zones from SDOT to the operator and has pricing disclosed to SDOT and the rider, never through the feed (GOB-254), so the integration expects neither.

Measured on 2026-11-08: about 12,700 vehicles, a vehicle file of 2.8 MB in 3.0 and 2.9 MB in 2.2, the 2.2 one about 460 KB compressed with gzip, `ttl` 60 seconds for the vehicle file and 86,400 for `vehicle_types`. Lime's files also carry a `vehicle_type` string GBFS does not define, which the client does not read.

Vehicle type identifiers differ between versions for the same vehicle: a standing scooter is type `2` in 2.2 and type `8` in 3.0. A vehicle's type is looked up in the `vehicle_types` of the version its vehicle file came from, never another.

## Terms and use

Lime's Public GBFS Terms govern the feed. The use gobusgo makes of it was settled on 2026-11-08 (GOB-253): public display with attribution in a free, non-commercial app, and raw responses kept for at most 10 minutes. The user read the terms and confirmed that use fits them; no agent has read their text, since li.me refuses automated fetches. The 3.0 `system_information` names the same terms as its `license_url`, and the 2.2 one names <https://www.li.me/gbfs-terms>. A use beyond the settled one needs the terms read again first.

The feed's existence rests on one clause of Seattle's permit, which requires a public GBFS feed and names no version (Appendix E.1.1(b), GOB-254). Lime serves 1.0, 2.2, and 3.0 by choice, and the permit can end on 30 days' notice, so a version that disappears, or the whole feed, is a known outcome rather than a failure.

## Auth and configuration

The feeds are public: no key, no account, and no credential of any kind. A request carries no query, no cookie, and no data about a rider; it sends `accept: application/json`, `accept-encoding: gzip`, and `user-agent: gobusgo`. A system is described to the client by its discovery address per version and the language a 1.0 or 2.2 discovery file is read in; no setting holds one yet.

## Contract the client encodes

`Gobusgo.Gbfs.Client.fetch/3` reads one file, `:vehicle_status` or `:vehicle_types`, of a system. It tries each version the system names, newest first, and passes a version over, then tries the next, when its discovery file answers 404, when the discovery file lists no such file, or when the file itself answers 404: GBFS allows an optional file to answer 404 and names that no error. Any other outcome ends the fetch with the version that gave it. A fetch where every version is passed over returns `:not_published`, with the reason each version was passed over. `:vehicle_types` is never tried in 1.0, which has no such file.

- **Bounds.** A body is at most 8 MiB as received and once expanded from gzip, about three times the 2.9 MB measured. The caller passes `:deadline_ms`, which bounds every request of the fetch together and is to be shorter than the interval of the source that calls it. Each connection has 5 seconds to open and each response 10 seconds between bytes.
- **No retries.** A source that runs every minute retries by running again, and a retry inside the deadline would spend the time the deadline gives the fallback.
- **Statuses.** 200 is data and 404 a passed-over version. A 3xx is never followed and is a failure, as is every other status, a network fault, a body over the cap, a content encoding other than gzip, a body that is not JSON, a file address that is not HTTPS, and a file that breaks its version's format. A failure names its cause, its version, and its file.
- **Formats.** The version the system names decides the format a file is read in: 1.0 and 2.2 write timestamps as POSIX seconds and 3.0 as RFC 3339 strings, and 1.0 writes `is_reserved` and `is_disabled` as 1 or 0.

## Identifier rotation

GBFS requires an operator to rotate a vehicle's identifier, `bike_id` or `vehicle_id`, to a random string after each trip, to protect riders' privacy. The client passes the identifier through and nothing may key a record, a trail, or a comparison on it across fetches: within one fetch it tells two vehicles apart, and that is all. Two Lime fetches taken a minute apart on 2026-11-08 shared about 12,680 of about 12,740 identifiers, and the 2.2 and 3.0 files of one moment name a vehicle by the same identifier; whether Lime rotates after every trip is not verified.

## Using the client from the rest of the codebase

Call `fetch/3` from a scheduler source's run, never from a page or a request path, so the one flow of `lib/gobusgo/AGENTS.md` ("Data flow") holds. Store `body`, the file as received, through the writer when a raw response is to be kept, within the 10 minutes the terms allow. Read `version` beside the records, and fetch `vehicle_types` with `versions: [version]` of the vehicle fetch it is joined to. Handle `:not_published` as a feed that is gone and a failure as a fetch to try at the next run; neither is an exception.

## Shared vehicles

`Gobusgo.Gbfs.VehicleStatusCycle` is the scheduler source of the vehicle file (GOB-256). Its policy is `{:on_demand, %{interval_ms: interval_ms}}` over the holders of `Gobusgo.Gbfs.DemandKey.shared_vehicles/0` in `Gobusgo.Demand`, the key a page holds while it shows the shared vehicle layer: the source is paused, and makes no request, while nothing holds it, and fetches once per interval while one or more pages do, for all of them together. The interval is `Gobusgo.Config.fetch_shared_vehicles/1`'s, validated at start, 60 seconds by default, the feed's `ttl`, and between 60 seconds and an hour. The scheduler starts the first run after a quiet period on the first tick once a viewer arrives, when the interval has elapsed since the last run started, and always after a start. The run's deadline is 45 seconds, and the fetch's 20.

Each run records every system through `Gobusgo.Gbfs.VehicleStatusRecorder`. A fetched file is stored as received under `raw/gbfs/free-bike-status/dt=<date>/system=<system>/<fetchedAt>_<requestId>_v<version>_<hash12>.json.gz` (`Gobusgo.Gbfs.RawVehicleStatus`), and its "response stored" event goes to `gbfs.free-bike-status.response-stored`, which the response consumer hands to `Gobusgo.Gbfs.VehicleStatusBatch`. The processor publishes one record per fetch to `gbfs.free-bike-status.state` (`Gobusgo.Gbfs.VehicleStatusBatch.Records`): every vehicle, the version that answered, and the file's `last_updated` and `ttl`. A file over 30,000 vehicles is refused and nothing is stored. `Gobusgo.Gbfs.VehicleStatusView` holds each system's newest record whole, starts empty, and is read with `current/2` and `vehicles/2`. Nothing is keyed on a vehicle identifier: a fetch replaces the one before it, a fetch with no vehicles empties it, and there are no tombstones.

A fetch where every version is passed over, as for a feed that answers 404, is a known outcome (GOB-254): nothing is stored, the recorder publishes a record that the feed is not published, after which the view holds no vehicle for the system, and the cycle logs `Shared vehicle feed not published` at `warning` once, while the view's entry is not already that record. Any other failure logs `Shared vehicles not recorded` at `error`, and a recorded fetch `Shared vehicles recorded` at `info`.

`Gobusgo.Gbfs.VehicleStatusRetention` keeps a stored file at most 10 minutes, the time the terms allow. It deletes, through the deleter, every file fetched more than 8 minutes 29 seconds before, which leaves room for one run interval, one deadline, and one scheduler tick inside the 10 minutes. It runs after each recorded fetch and as a source of its own once a minute, viewed or not, so the last fetches go once viewing ends and a start removes what an earlier run left. A run lists the last three UTC days of each system and deletes at most 1,000 files, and logs at `error` when a listing or a deletion fails. `Gobusgo.RetentionPolicy` keeps the dataset one day as a backstop, and so does the bucket's lifecycle rule for `raw/gbfs/free-bike-status/` in the infrastructure repository (GOB-266).

One fetch of 12,700 synthetic vehicles holds 7.9 MiB in the view's table, and one of 30,000 holds 18.5 MiB (`mix test --only memory`, 2026-11-08).

## Publishing to the browser

Pages draw the shared vehicles from static files, never from LiveView events, and the browser downloads them from gobusgo, never from the operator's feed (GOB-258). After each run's fetch of a system, the cycle hands the view's entry to `Gobusgo.Gbfs.VehicleTiles.Build`: a fetch is published, and a feed found not published drops the system's index, so pages stop drawing it. A failed fetch leaves both as they were.

`Gobusgo.Gbfs.VehicleTileSet` is pure and builds a fetch's files in the fetch's own directory, `shared-vehicles/dt=<date>/system=<system>/<fetchedAt>_<requestId>/`, each named by the first 16 hexadecimal characters of the SHA-256 of its content and stored compressed with gzip:

- `tile-14-<x>-<y>-<hash>.bin.gz`, one per Web Mercator tile of zoom 14 that holds a vehicle;
- `city-<hash>.bin.gz`, every vehicle, for the trip planner, which reads the whole city so that no request names where the rider is (GOB-259);
- `index-<hash>.json.gz`, the fetch's time, version, and vehicle count, the whole-city file's name, and each tile as `[x, y, count, hash]`.

A vehicle is published where the file gives it a position and it is neither disabled nor reserved. A tile and the whole-city file are blocks of `Gobusgo.Gbfs.VehicleTileFormat`: a header with the bounds, then one column each of latitude and longitude as `u16` fractions of the bounds, the remaining range as `u16` decameters, and the form factor of `Gobusgo.Gbfs.VehicleForms.lookup/2` as a `u8`, 7 bytes a vehicle. No file holds a vehicle identifier, so nothing published can follow a vehicle across fetches. The columns compress little, because positions are spread evenly, and that is accepted: the bytes are those of the vehicles in view, and JSON with names would be several times larger. The whole-city file of 12,528 vehicles on 2026-11-08 was 69 KB compressed, and the index 2.1 KB.

Zoom 14 is the tile zoom because the vehicles in view set the bytes a page downloads, and a tile much larger than a phone's view adds those of the area around it. Measured on one live fetch on 2026-11-08, a phone's view at map zoom 15 needs 2.9 KB a fetch in Ballard and 23 KB downtown at zoom 14, against 7.6 KB and 35 KB at zoom 13. Zoom 15 brought downtown down only to 17 KB and needs about three times the files. Zoom 14 is 108 files a fetch; with S3 that is 108 writes a minute, only while some page shows the layer. One zoom is enough, since the layer shows only from map zoom 14, where a desktop view spans about 12 tiles and a phone's 1 to 4.

`Gobusgo.Gbfs.VehicleTiles.Build` writes the tiles and the whole-city file, then the index, and only then makes the index current in `Gobusgo.Gbfs.VehicleTiles`, so a current index never names a missing file; a write that fails keeps the index before and logs `Shared vehicle tiles not written` at `error`. `Gobusgo.Gbfs.VehicleStatusRetention` deletes the published files with the stored file of their fetch, by the fetch time their directory names, within the same ten minutes, and `Gobusgo.RetentionPolicy` and the bucket's lifecycle rule for `shared-vehicles/` keep them a day as a backstop (GOB-268). The endpoint serves them under `/shared-vehicles` as the gzip streams they are, cacheable for 60 seconds, and a page hands the browser only an index whose fetch is at most three minutes old, so no cache holds a file past the ten minutes either. With a bucket configured, CloudFront serves `/shared-vehicles/*` from the bucket and caches a file at most 60 seconds (GOB-268).

The page's side is in `lib/gobusgo_web/live/AGENTS.md` ("Shared vehicles layer"): the layer's toggle holds `Gobusgo.Gbfs.DemandKey.shared_vehicles/0`, and the browser reads an index, then the tiles in view.

## Credit and the About section

`Gobusgo.Gbfs.Systems` names each system's operator, the terms its feed is published under, and their address; the Settings tab's About group credits each operator with a link to its terms, Lime's Public GBFS Terms for Lime. Its texts, from `GobusgoWeb.AppInfo.shared_vehicles/1`, are built from what the code does: the vehicle file names of `Gobusgo.Gbfs.Files`, the configured interval, the vehicle type cadence, and the age `Gobusgo.Gbfs.VehicleStatusRetention` keeps a response, so a change to any of them changes what a rider reads, and a test checks the panel against them.
## Vehicle types

`Gobusgo.Gbfs.Systems` names the systems read, Lime Seattle alone, each as `fetch/3` takes it with its catalog identifier beside it. `Gobusgo.Gbfs.VehicleTypesCycle` runs once a minute, with a deadline of 55 seconds and a budget of 50, and fetches `vehicle_types` for each system at each version that publishes it, 3.0 and 2.2 for Lime, each with `versions: [version]` and a 15-second deadline of its own. An item, one system at one version, is held in the view as `<system id>/<version>` and gets a slot of its own from `Gobusgo.OneBusAway.RouteSchedule`, a minute of the UTC day: it is due with no attempt in the view and once its slot has come since its last attempt, so the first cycle after a start fills the empty view and each item then refreshes once a day, as the file's `ttl` of 86,400 seconds asks. Fetching every version, rather than the one the vehicle source last answered at, gives the vehicles of whichever version answers their types with no dependency on that source.

A fetched file is published as one record of `Gobusgo.Gbfs.VehicleTypeRecords` to `gbfs.vehicle-types.state`, which the in-process publisher hands to the fetch view `Gobusgo.Gbfs.VehicleTypeView`. A version whose discovery file or `vehicle_types` answers 404, or whose discovery file lists no `vehicle_types`, is `:not_published`: the cycle notes an attempt in the view, so the item waits for its slot, and the view keeps the types of that version it holds. A failed fetch notes nothing and is fetched again at the next cycle. No raw `vehicle_types` response is stored, so the 10-minute bound of the terms has nothing of this file to apply to: the file is a few hundred bytes and fetched again on its slot, and the view holds the parsed types alone.

`Gobusgo.Gbfs.VehicleForms.lookup/2` is pure: from the view's current fetches and a vehicle's system, version, and type identifier it gives the vehicle's form factor, `:standing_scooter`, `:seated_scooter`, `:e_bike`, `:bike`, or `:other`, and its type's `max_range_meters`. A type the fetch of that system and version does not hold, a vehicle with no type, and every vehicle of a 1.0 fetch are `:other` with no range. 2.2 names one `scooter` form factor, which is read as a standing scooter, since 2.2 has no seated one.
