# How the server works

The server is one Elixir application. It fetches transit and bike data, stores every response, holds the processed records in memory, serves the live map, and publishes the files the browser plans and searches with. It needs no database and no message broker.

## The data flow

> *Where does the data go after the server fetches it?*
>
> Down one road, every dataset the same way. One road is easy to follow and hard to get lost on.

```mermaid
flowchart LR
  F[Fetch] --> R[Store the raw response]
  R --> E[Response stored event]
  E --> P[Process into records]
  P --> V[In-memory view]
  V --> W[Pages, API, and published files]
```

1. A scheduler runs a source at its cadence.
2. A recorder stores the raw response, compressed, and announces it with a "response stored" event.
3. A processor reads the stored response and turns it into records.
4. A view holds the records in memory for the pages, the API, and the AI assistant tools.

Because the raw response is stored first, any view can be rebuilt from storage, and a response that fails to process is replaced by the next fetch rather than retried. Views start empty on every start; the route and stop views are rebuilt from the last two days of stored responses, and the rest fill from the next fetch.

## Fetching on demand

> *Does it fetch everything all the time?*
>
> Heavens, no. It fetches hard when someone is watching and idles when no one is. Good manners toward the data provider, and toward the electric bill.

| Data | Cadence |
| --- | --- |
| Agencies | Once a minute |
| Vehicles | Every 10 seconds while a map page is open and for a minute after the last one closes, once a minute otherwise |
| Routes and route paths | Once a day per item, each at its own minute |
| Route schedules | Once a day per route, for the next day, so yesterday, today, and tomorrow are always held |
| Arrivals | Only for the stops someone has open, one request every 5 seconds shared among them |
| Shared bikes and scooters | Only while a page shows them |

A demand registry tracks what pages and assistant tools are looking at, such as their open stops, and the schedulers read it to decide what to fetch. A failed run backs off for 1, 3, 7, then 15 intervals, and a run that passes its deadline is stopped.

## Published files

From its views the server builds the files the browser reads:

- **Routing snapshots**, one per service date, rebuilt every ten minutes when a schedule, a stop position, or a name has changed. Vehicle positions never trigger a build. [How the browser routes with them](algorithms.md#trip-planning).
- **Trip path files**, the road path of every trip, sharded by route.
- **The route and stop tile archive**, which draws the route lines and stops on the map.
- **Places, address, and intersection files**, built by hand from OpenStreetMap and county data. [How the browser searches them](algorithms.md#search).
- **The basemap**, regional PMTiles archives cut from a Protomaps build, read by the map with HTTP range requests.

A file's name carries the hash of its contents, so a browser caches it for as long as it likes, and a manifest names the current set.

## Endpoints

| Path | What |
| --- | --- |
| `/vehicles` | The live map, with arrivals, favorites, alerts, trip planning, and settings |
| `/agencies` | The agencies and their coverage areas |
| `/api/agencies`, `/api/agencies/{id}` | The same, as JSON |
| `/api/routing/manifest` | The routing snapshots of the held service dates |
| `/health`, `/ready` | Whether the server is up, and whether its views are filled |
| `/mcp` | The Model Context Protocol endpoint |

`priv/openapi.json` describes the public endpoints and `priv/openapi.private.json` the operational ones. An agency endpoint answers `503` until the first agency fetch is processed, and a fresh start takes about ten minutes to answer `/ready` with success.

## AI assistant tools

> *How does a chatbot know when my bus comes?*
>
> It asks politely, over the Model Context Protocol, and gets the same answer the map would give.

| Tool | Answers |
| --- | --- |
| `find` | Agencies, routes, and stops matching some text |
| `vehicles` | The vehicles of chosen agencies or routes |
| `arrivals` | A stop's upcoming arrivals |
| `arrivals_board` | The same, as a live board an assistant can show |
| `alerts` | Current and upcoming service alerts for routes or stops |
| `route` | A route's directions and the stops of each |
| `plan_trip` | A trip plan, computed by the same in-browser planner inside the assistant's app frame |

The server keeps no session. An `arrivals` call holds its stop in the demand registry for 60 seconds, at most ten stops at once, so assistant requests share the arrival source's one request stream and never raise the request rate to the data provider.

## Usage records

The server writes one record each time a page disconnects, and one per assistant request, to count visits. A record holds when the page connected and for how long, which page it was, the last filter it showed, the device class, the browser family, a range of window widths, the browser's language, and the host of the referring site. It holds no IP address, no cookie, no user agent, and no identifier of a visitor, so two visits by the same person cannot be told apart. Records are kept three days.

## Retention

Stored files are deleted once past their dataset's retention:

| Files | Kept |
| --- | --- |
| Vehicle and arrival responses | 1 day |
| Agency, route, and route path responses | 30 days |
| Usage records | 3 days |
