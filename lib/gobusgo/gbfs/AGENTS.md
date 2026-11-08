# GBFS integration

The General Bikeshare Feed Specification (GBFS) is the open format in which shared bike and scooter operators publish where their vehicles are. Gobusgo reads it through one generic client, so any operator that publishes a feed is read the same way; today the one system it serves is Lime Seattle, the only operator Seattle's free-floating micromobility permit names (GOB-254). The client reads three files: the discovery file `gbfs.json`, the vehicle file (`free_bike_status` in 1.0 and 2.2, `vehicle_status` in 3.0), and `vehicle_types` (2.2 and 3.0). `Gobusgo.Gbfs.VehicleTypesCycle` fetches the vehicle types once a day (GOB-257), as the "Vehicle types" section below holds; GOB-256 adds the source that fetches the vehicles while a page shows them.

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

Call `fetch/3` from a scheduler source's run, never from a page or a request path, so the one flow of the root `AGENTS.md` holds. Store `body`, the file as received, through the writer when a raw response is to be kept, within the 10 minutes the terms allow. Read `version` beside the records, and fetch `vehicle_types` with `versions: [version]` of the vehicle fetch it is joined to. Handle `:not_published` as a feed that is gone and a failure as a fetch to try at the next run; neither is an exception.

## Vehicle types

`Gobusgo.Gbfs.Systems` names the systems read, Lime Seattle alone, each as `fetch/3` takes it with its catalog identifier beside it. `Gobusgo.Gbfs.VehicleTypesCycle` runs once a minute, with a deadline of 55 seconds and a budget of 50, and fetches `vehicle_types` for each system at each version that publishes it, 3.0 and 2.2 for Lime, each with `versions: [version]` and a 15-second deadline of its own. An item, one system at one version, is held in the view as `<system id>/<version>` and gets a slot of its own from `Gobusgo.OneBusAway.RouteSchedule`, a minute of the UTC day: it is due with no attempt in the view and once its slot has come since its last attempt, so the first cycle after a start fills the empty view and each item then refreshes once a day, as the file's `ttl` of 86,400 seconds asks. Fetching every version, rather than the one the vehicle source last answered at, gives the vehicles of whichever version answers their types with no dependency on that source.

A fetched file is published as one record of `Gobusgo.Gbfs.VehicleTypeRecords` to `gbfs.vehicle-types.state`, which the in-process publisher hands to the fetch view `Gobusgo.Gbfs.VehicleTypeView`. A version whose discovery file or `vehicle_types` answers 404, or whose discovery file lists no `vehicle_types`, is `:not_published`: the cycle notes an attempt in the view, so the item waits for its slot, and the view keeps the types of that version it holds. A failed fetch notes nothing and is fetched again at the next cycle. No raw `vehicle_types` response is stored, so the 10-minute bound of the terms has nothing of this file to apply to: the file is a few hundred bytes and fetched again on its slot, and the view holds the parsed types alone.

`Gobusgo.Gbfs.VehicleForms.lookup/2` is pure: from the view's current fetches and a vehicle's system, version, and type identifier it gives the vehicle's form factor, `:standing_scooter`, `:seated_scooter`, `:e_bike`, `:bike`, or `:other`, and its type's `max_range_meters`. A type the fetch of that system and version does not hold, a vehicle with no type, and every vehicle of a 1.0 fetch are `:other` with no range. 2.2 names one `scooter` form factor, which is read as a standing scooter, since 2.2 has no seated one.
