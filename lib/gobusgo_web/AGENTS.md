# HTTP server and browser pages

`lib/gobusgo_web/` holds the Phoenix site on Bandit (the choice and its rationale are in GOB-17): the endpoint, the router, the controllers, the LiveView pages, the components, and the pure modules that turn the views into what a page shows. The vehicle page has a file of its own, `live/AGENTS.md`, and the JavaScript and CSS it runs are in `assets/AGENTS.md`.

## Files

- `endpoint.ex` and `router.ex` are the endpoint, with its static file plugs, and the router.
- `controllers/` holds the health, readiness, agency, routing manifest, and address manifest controllers, `FallbackController`, and the error bodies `ErrorJSON` and `ErrorHTML`; `problem.ex` writes problem details.
- `live/` holds the LiveView pages: `home_live.ex`, the placeholder at `/`, `agency_live.ex`, the test page at `/agencies`, and `vehicle_live.ex` with `vehicle_live/`, the vehicle page.
- `components/` holds the layouts and the function components: `layouts.ex`, `panel_sheet.ex`, `vehicle_filter_form.ex`, `app_info_panel.ex`, `service_alerts_panel.ex`, `shared_vehicle_toggle.ex`, `connection_signal.ex`, `donation_button.ex`, and `message.ex`.
- `public_host.ex` turns the public host name into the endpoint's options, and is pure.
- `usage_hook.ex` is the mount hook that registers every page of the live session with the usage recorder, and `connection_facts.ex` validates what the browser connects with and is pure.
- `service_worker.ex`, `GobusgoWeb.ServiceWorker`, gives the service worker build its constants, and is pure; `map_library.ex` names where a page loads MapLibre from, a directory that carries the version `assets/vendor.lock.json` pins, read at compile time, and is pure.
- `basemap_sources.ex` names where a map page loads its basemap from, the library's address included, the view it opens with, and the bounds of the whole archive, and is pure.
- `map_extent.ex` gives the bounds a map fits to show a set of positions, and is pure.
- `vehicle_markers.ex` turns one agency's fetch into the markers a map page draws, each with its status and the texts of its lateness and next stop, and is pure.
- `route_lines.ex` turns the two route views into the lines of the tile archive, and `stop_markers.ex` a stop of the stop view into its marker and says whether a map that draws a set of routes draws the stop; both are pure.
- `stop_arrivals.ex` turns a stop's fetch of the arrivals view and the vehicles of the vehicle view into the arrivals a page shows, and is pure.
- `service_alerts.ex` turns the two situation views into the current and upcoming alerts of the routes a filter keeps, and is pure.
- `filter_params.ex` reads a raw filter out of query parameters, a field's values separated by commas, and writes a filter as a query string.
- `agency_options.ex` and `route_options.ex` give the options of a filter by agency and by route, and `filter_bar.ex` the tokens and suggestions of the filter bar from them; all three are pure.
- `app_info.ex` holds the texts of the vehicle page's info panel, the data terms, and the license of each thing a page ships, and is pure.
- `route_stop_tiles.ex` and `route_stop_tiles/` are the route and stop tile archive.

## Routes

- `GET /health` answers `{"status": "ok"}`, with `revision`, the full commit the application was built from, where the build names one. It is the image's liveness check, says nothing of the views, and is not logged.
- `GET /ready` answers `{"status": "ready"}` once `Gobusgo.OneBusAway.Readiness` finds the views full, and `503` problem details with `Retry-After` before that. It reads the views, starts no fetch, and is not logged.
- Both answers also hold `tiles`, the freshness of the current route and stop tile archive: `"current"`, `"stale"`, or `"none"`, with `tilesAgeSeconds` beside it. The archive never changes the status or the code, so a failing tile build leaves the site served, and no destination is named (decided in GOB-229).
- API routes go under `/api`: `GET /api/agencies` and `GET /api/agencies/:id` serve the current fetch of the agency view, and `GET /api/routing/manifest` the manifest of the routing snapshots, with `cache-control: no-cache` and an `etag`, answering `304` to a request that names it. `GET /api/addresses/manifest` answers every county's manifest of the address shards the same way, `{"counties": [...]}`, from `Gobusgo.Addresses`, and `503` problem details with `Retry-After: 60` while no county is built (GOB-361, GOB-363). `GET /api/intersections/manifest` answers the manifest of the intersection files the same way, read through `Gobusgo.Reader` on each request, the newest of the manifests the builds store, and `503` problem details with `Retry-After: 60` while none is stored or the stored one is malformed (GOB-364).
- `GET /` is a placeholder page, `GET /agencies` a test page that lists the agencies of the agency view's current fetch and updates when the view switches, and `GET /vehicles` the vehicle page (`live/AGENTS.md`).
- The LiveView socket is at `/live`, over WebSocket only.

## Response bodies and errors

- Success bodies hold `data` and `meta`. `meta` names the fetch the data comes from (`fetchedAt`, `requestId`), and a collection adds `count`. A route whose view has no current fetch answers `503` problem details with `Retry-After`, never an empty `200`.
- A JSON error is an RFC 9457 problem details object, served as `application/problem+json`, with `type` (`about:blank`), `title`, and `status`. `detail` appears only for an error whose explanation the application writes itself, so the message of an unexpected error never reaches a client.
- Every error under `/api` is problem details: `GobusgoWeb.FallbackController` answers the requests no API route matches. Elsewhere the error is an HTML page from `GobusgoWeb.ErrorHTML` for a request that accepts HTML first, and problem details otherwise.
- Plugs that can raise go in a router pipeline, never in the endpoint: the endpoint registers the callback that sets the problem media type, and only an error raised inside the router reaches the error renderer with that callback. `Plug.Static` is the one exception, because it runs before the router.

## Static files

The endpoint serves these through `Plug.Static` plugs, one per kind. A file they serve is answered before the request logger, so it leaves no log line.

- The service worker at `/sw.js`, with `cache-control: no-cache`, so a browser that checks for a new release never gets an old worker from a cache, and the built assets, `/manifest.webmanifest`, and its icons under `/icons/` at the root. Production serves these from the application through CloudFront once the gobusgo-infra change of GOB-250 is applied.
- The vendored archives under `/vendor/<archive>/<path>` from `priv/vendor`, cacheable for an hour. The one archive is `basemaps-assets`, the basemap's fonts and sprites.
- The basemap files under `/basemap/<name>` from `<GOBUSGO_DATA_DIR>/basemap`, through two plugs: every file whose name starts with `basemap-`, the archives and their offline extracts, cacheable for an hour, and `manifest.json`, revalidated on every use. A request with a `range` header gets `206` with that part of the file, which is how a PMTiles reader reads tiles. The pages and the archives share one origin, so no CORS header is set.
- The route and stop tile archives under `/tiles/<path>` from `<GOBUSGO_DATA_DIR>/tiles`, with ranges, cacheable for a year as immutable since each archive's name is that of its own build. The year is `GobusgoWeb.RouteStopTiles.reader_keep_seconds/0`, which the plug's header and every build's write both read; a file that is not there answers the router's 404. With a bucket the archives are in S3, each stored with that `Cache-Control`, and production serves `/tiles/*` from the bucket through CloudFront (GOB-218, GOB-221).
- The routing snapshot files under `/routing/<path>` from `<GOBUSGO_DATA_DIR>/routing`, cacheable for a year as immutable, since each file's name holds the SHA-256 of its content. With a bucket the files are in S3, and production serves `/routing/*` from the bucket through CloudFront.
- The places file under `/places/<name>` from `<GOBUSGO_DATA_DIR>/places`, through two plugs: every file whose name starts with `places-`, answered as the gzip stream it is stored as, `application/gzip` with no content encoding, cacheable for a year as immutable since the name holds the SHA-256 of the stream, and `manifest.json`, which names the current file, and `NOTICE.txt`, the license notice, as `text/plain; charset=utf-8`, each with `no-cache` and an `etag`. With a bucket the files are in S3 and production needs a CloudFront behavior for `/places/*` that the infrastructure repository does not have yet (GOB-366; `lib/gobusgo/places/AGENTS.md`).
- The intersection files under `/intersections/<name>` from `<GOBUSGO_DATA_DIR>/intersections`, the files whose name starts with `intersections-`, each answered as the gzip stream it is stored as, `application/gzip` with no content encoding, cacheable for a year as immutable since the name holds the SHA-256 of the stream; the manifest in that directory is not served from it but at `/api/intersections/manifest`. The files are a derivative database of OpenStreetMap, offered under the ODbL. With a bucket the files are in S3 and production serves `/intersections/*` from the bucket through CloudFront once gobusgo-infra #56 is applied (GOB-364; `lib/gobusgo/intersections/AGENTS.md`).
- The address shard files under `/addresses/<path>` from `<GOBUSGO_DATA_DIR>/addresses`, each answered as the gzip stream it is stored as, `application/gzip` with no content encoding, cacheable for a year as immutable, since each file's name holds the SHA-256 of its stream (`lib/gobusgo/addresses/AGENTS.md`). The year is `Gobusgo.Addresses.reader_keep_seconds/0`, which the plug's header and every build's write both read. With a bucket the files are in S3, and production serves `/addresses/*` from the bucket through CloudFront once the infrastructure change of GOB-365 is applied.
- The shared vehicle files under `/shared-vehicles/<path>` from `<GOBUSGO_DATA_DIR>/shared-vehicles`, each answered as the gzip stream it is stored as, `application/gzip` with no content encoding, which the browser expands with `DecompressionStream`, so the same bytes reach a page from the local directory and from S3. A cache may keep each as immutable for 60 seconds, which keeps no copy past the ten minutes Lime's terms allow. Production needs a CloudFront behavior for `/shared-vehicles/*`, which the infrastructure repository does not have yet (GOB-258).

## Compression

Every response leaves compressed when the client accepts it. Bandit compresses the bodies the application sends, and the LiveView socket offers per-message deflate. The built assets and the vendored files are answered with the gzip copy beside them, `<file>.gz`, which `mix phx.digest` writes for the built assets, `.mjs` included through `config/config.exs`, and `mix gobusgo.vendor.fetch` writes for each `.json`, `.pbf`, and `.txt` file of an archive. The basemap archives are sent as they are, because their tiles are compressed inside them and a range response carries no encoding.

## Browser pages

- Browser pages are LiveViews routed through the `:browser` pipeline, in one live session, rendered inside `GobusgoWeb.Layouts.root/1`.
- The root layout titles a page from its `page_title` assign as "<`page_title`> · Gobusgo", or "Gobusgo" alone for a page that names none (GOB-306).
- The root layout names the build's commit in `<meta name="revision">`, the WHATWG MetaExtensions name, where the build names one, and the render time in UTC to the millisecond in `<meta name="gobusgo:rendered-at">`, from which the browser tells a copy from a cache.
- The root layout runs an inline script before the stylesheet that sets the root element's `data-theme` from the stored theme setting, and the content of its one `theme-color` meta element to that theme's page background, so the first paint and the browser's status bar and overscroll are in the rider's theme whatever the system's mode (GOB-342). It links the web app manifest and the home screen icon, and ends the body with the hidden offer to reload into a new release.
- The live session's mount hook, `GobusgoWeb.UsageHook`, registers each connected page with the usage recorder, so a page added to the session is recorded with no code of its own, under its module's name in snake case less `_live`. A page mounts whatever the recorder answers.
- The browser connects with `client.viewport_width`, `client.language`, and `client.referrer_host`, which `assets/js/app.js` sends and `GobusgoWeb.ConnectionFacts` validates; the socket hands the page the user agent and the address it connected with.
- Every page holds the element of the `ConnectionState` hook, from `GobusgoWeb.ConnectionSignal.state_hook/1`.
- Where `GOBUSGO_DONATION_URL`, read by `Gobusgo.Config.donation_url/0`, names an `https` address, every page shows the donation button of `GobusgoWeb.DonationButton`, a link named "Support gobusgo on Ko-fi" that opens in a new tab with `rel="noopener noreferrer"`. The page requests nothing from the donation site until the rider follows it. With the variable unset or blank no page shows it, and a value that is not an `https` address with a host stops the application at startup. `GET /` and `GET /agencies` hold the button in a `<header>`, so it stands in a landmark.
- A status or error message is a bold headline that states the state and a muted caption with the next step or the detail (GOB-327): `GobusgoWeb.Message` renders one on the server and `assets/js/message.js` in the browser, the headline ending in a visually hidden full stop, so a live region reads two sentences.
- A page shows a value from outside the application as a link only when it is an `http` or `https` address.

## Session and origin

- The session is a signed cookie. `SECRET_KEY_BASE` supplies the secret: production refuses to start without it, and development and test generate a random one at startup when it is unset. The signing salts in the code are not secrets.
- `GOBUSGO_PUBLIC_HOST` names the host pages are served on: with it set the socket accepts a page of that host under any scheme and port and refuses every other origin, and production refuses to start without it. With it unset, outside production, the socket accepts any origin.
- The endpoint's generated URLs take the host and no scheme or port, because nothing generates an absolute URL.

## Route and stop tile archive

- `GobusgoWeb.RouteStopTiles` is a PMTiles archive of the lines and stops a map page draws with no filter, stored through the writer at `tiles/route-stops/dt=<date>/route-stops-<UTC time>-<SHA-256 of its features>.pmtiles`, and the process, started on every start, that holds the current archive's destination and the hash of its features. The vehicle page draws its lines and stops from it (GOB-219).
- After a start it finds the newest stored archive with `Gobusgo.Reader.discover/2` and reads both from its name, so a start from the same views builds nothing (GOB-277); an archive whose name holds no hash leaves it unknown and the first check builds. It logs `Route stop tiles discovery failed` at `warning` when it cannot.
- Its scheduler, where the sources are scheduled, checks every ten minutes and builds only when the hash of the features it would write differs from the current archive's (GOB-222), or when the current archive is a day less than its retention old, so the retention never deletes the archive a page points at (GOB-226).
- `freshness/1` judges an archive current or stale against that renewal age, `GobusgoWeb.RouteStopTiles.Build.renewal_age_seconds/0`, by the build time its name holds, and is pure; `/ready` reports it.
- `route_stop_tiles/build.ex` is one run: it reads the views, writes the features of `route_stop_tiles/features.ex`, which is pure, runs tippecanoe on them with a deadline, stores the archive, and logs `Route stop tiles built` at `info` or `Route stop tiles not built` at `error`. Without tippecanoe a build logs its failure and the application runs on.
- A route's feature holds `routeId`, `color`, `shortName`, `longName`, and `agencyName`. A stop's, from zoom 14, holds `stopId`, `name`, `code`, `direction`, `routes`, `agencies`, `routeIds`, and `routeChips`: each named route's name and CSS color as a JSON list of pairs, and its drawn routes with a comma before, between, and after them, so a layer filter matches the substring `,<id>,`.

## Tests

Tests send requests through the endpoint with `Phoenix.ConnTest` and mount pages with `Phoenix.LiveViewTest`; no socket is opened and no test runs the JavaScript. `test/gobusgo_web/accessibility/rendered_pages_test.exs` renders the browser pages and checks them against `Gobusgo.Test.Accessibility`, as the root file's toolchain section describes.
