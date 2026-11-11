defmodule GobusgoWeb.Endpoint do
  @moduledoc """
  The HTTP endpoint: the LiveView socket, and the plugs every request passes
  through before the router. The socket hands a page the user agent and the
  address it connected with, which `GobusgoWeb.UsageHook` reads. `Gobusgo.Application` starts it with the
  listener address and the secret that signs the session.

  A JSON response with an error status leaves as `application/problem+json`,
  unless the controller called `keep_json_content_type/1`.
  A request for `/health` or `/ready` is not logged. Built assets are served
  from `priv/static`. The socket offers per-message compression.

  The vendored archives of `priv/vendor` are served under `/vendor`, and a
  cache may keep a file for an hour. A built asset or a vendored file that
  has a gzip copy beside it, `<name>.gz`, is answered with the copy to a
  client that accepts gzip.

  The basemap directory is served under `/basemap`: every file whose name
  starts with `basemap-`, and `manifest.json`. A response carries
  `accept-ranges: bytes` and an `etag`, and a request with a `range` header
  gets that part of the file as `206`, which is how a PMTiles reader takes
  the tiles it needs out of an archive. A cache may keep an archive for an
  hour and has to revalidate the manifest on every use, because the manifest
  names the archives in use.

  The locally stored route and stop tile archives are served under `/tiles`,
  from the tile directory, with ranges as the basemap archives are. A cache
  may keep an archive as immutable for
  `GobusgoWeb.RouteStopTiles.reader_keep_seconds/0`, the time the archive's
  build stores it with, and a file that is not there falls through to the
  router with no such header.

  The locally stored routing snapshot files are served under `/routing`,
  from the routing directory. Each file's name holds the SHA-256 of its
  content, so a cache may keep it for a year as immutable.

  The locally stored places files are served under `/places`, from the
  places directory, as the gzip streams they are stored as, `application/gzip`
  with no content encoding. A file's name holds the SHA-256 of its stream, so
  a cache may keep it for a year as immutable; the manifest that names the
  current file and the license notice beside it, `NOTICE.txt` as UTF-8 text,
  have to be revalidated on every use.

  The locally stored address shard files are served under `/addresses`,
  from the address directory, as the gzip streams they are stored as.
  Each file's name holds the SHA-256 of its stream, so a cache may keep it
  for `Gobusgo.Addresses.reader_keep_seconds/0`, a year, as immutable.

  The locally stored intersection files are served under `/intersections`,
  from the intersections directory, as the gzip streams they are stored as.
  Each file's name holds the SHA-256 of its stream, so a cache may keep it
  for `Gobusgo.Intersections.Publication.reader_keep_seconds/0`, a year, as
  immutable. The manifest is not served from there: the router answers it at
  `/api/intersections/manifest`.

  The locally stored shared vehicle files are served under
  `/shared-vehicles`, from the shared vehicle directory, as the gzip
  streams they are stored as. Each file's name holds a hash of its
  content, so a cache may keep it as immutable, for a minute.

  The web app manifest, its icons under `/icons`, and the service worker
  are served at the root. A cache has to revalidate the service worker on
  every use, so a browser that checks for a new release never gets an old
  worker from a cache.
  """

  use Phoenix.Endpoint, otp_app: :gobusgo

  @json_content_type "application/json"
  # https://www.rfc-editor.org/rfc/rfc9457#section-3 — checked 2026-10-02
  @problem_content_type "application/problem+json"
  @error_status_min 400
  @json_body_key :gobusgo_json_body
  @health_path "/health"
  @readiness_path "/ready"
  @static_paths ["assets", "favicon.ico", "icons", "manifest.webmanifest", "robots.txt"]
  @service_worker_paths ["sw.js"]
  @vendor_path "/vendor"
  @vendor_cache_seconds 3_600
  @basemap_path "/basemap"
  @basemap_archive_prefix "basemap-"
  @basemap_manifest_name "manifest.json"
  @basemap_archive_cache_seconds 3_600
  @tiles_path "/tiles"
  @tiles_cache_seconds GobusgoWeb.RouteStopTiles.reader_keep_seconds()
  @routing_path "/routing"
  @routing_cache_seconds 31_536_000
  @places_path "/places"
  @places_file_prefix "places-"
  @places_manifest_name "manifest.json"
  @places_notice_name "NOTICE.txt"
  @places_cache_seconds Gobusgo.Places.Publication.reader_keep_seconds()
  @addresses_path "/addresses"
  @addresses_cache_seconds Gobusgo.Addresses.reader_keep_seconds()
  @intersections_path "/intersections"
  @intersections_file_prefix "intersections-"
  @intersections_cache_seconds Gobusgo.Intersections.Publication.reader_keep_seconds()
  @shared_vehicles_path "/shared-vehicles"
  # Lime's terms allow what a fetch holds to be kept ten minutes (GOB-253),
  # so a cache keeps a shared vehicle file a minute, well inside them.
  @shared_vehicles_cache_seconds 60

  # The session cookie lasts as long as LiveView's session token, 14 days in
  # Phoenix LiveView 1.2.12 (`@max_session_age` in
  # `Phoenix.LiveView.Static`), so a vehicle page the service worker saved
  # joins again with the cookie it was rendered under after the browser
  # restarts, and a saved copy older than that reloads once.
  @session_cookie_age_seconds 1_209_600

  # The salt separates the session's signing key from the other keys derived
  # from the secret; it is not itself a secret.
  @session_options [
    store: :cookie,
    key: "_gobusgo_session",
    signing_salt: "session",
    same_site: "Lax",
    max_age: @session_cookie_age_seconds
  ]

  @doc "How long the session cookie lasts, in seconds."
  @spec session_cookie_age_seconds() :: pos_integer()
  def session_cookie_age_seconds, do: @session_cookie_age_seconds

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [compress: true, connect_info: [:user_agent, :uri, session: @session_options]],
    longpoll: false

  # A plug that can raise goes in a router pipeline, never here. The router
  # hands the error renderer the connection that carries the callback
  # problem_content_type/2 registers; an error raised by a plug of this
  # module reaches the renderer with the connection as it arrived. Plug.Static
  # has to run before the router, so its error for a malformed asset path is
  # the one JSON error that leaves as `application/json`.
  # deps/phoenix/lib/phoenix/endpoint.ex, __before_compile__/1 — checked 2026-10-02
  plug :problem_content_type

  plug Plug.Static,
    at: "/",
    from: :gobusgo,
    gzip: false,
    only: @service_worker_paths,
    cache_control_for_etags: "no-cache"

  plug Plug.Static, at: "/", from: :gobusgo, gzip: true, only: @static_paths

  plug Plug.Static,
    at: @vendor_path,
    from: {:gobusgo, "priv/vendor"},
    gzip: true,
    cache_control_for_etags: "public, max-age=#{@vendor_cache_seconds}"

  plug Plug.Static,
    at: @basemap_path,
    from: {__MODULE__, :basemap_dir, []},
    gzip: false,
    only_matching: [@basemap_archive_prefix],
    cache_control_for_etags: "public, max-age=#{@basemap_archive_cache_seconds}"

  plug Plug.Static,
    at: @basemap_path,
    from: {__MODULE__, :basemap_dir, []},
    gzip: false,
    only: [@basemap_manifest_name],
    cache_control_for_etags: "no-cache"

  plug Plug.Static,
    at: @tiles_path,
    from: {__MODULE__, :tiles_dir, []},
    gzip: false,
    cache_control_for_etags: "public, max-age=#{@tiles_cache_seconds}, immutable"

  plug Plug.Static,
    at: @routing_path,
    from: {__MODULE__, :routing_dir, []},
    gzip: false,
    cache_control_for_etags: "public, max-age=#{@routing_cache_seconds}, immutable"

  plug Plug.Static,
    at: @addresses_path,
    from: {__MODULE__, :addresses_dir, []},
    gzip: false,
    cache_control_for_etags: "public, max-age=#{@addresses_cache_seconds}, immutable"

  plug Plug.Static,
    at: @intersections_path,
    from: {__MODULE__, :intersections_dir, []},
    gzip: false,
    only_matching: [@intersections_file_prefix],
    cache_control_for_etags: "public, max-age=#{@intersections_cache_seconds}, immutable"

  plug Plug.Static,
    at: @shared_vehicles_path,
    from: {__MODULE__, :shared_vehicles_dir, []},
    gzip: false,
    cache_control_for_etags: "public, max-age=#{@shared_vehicles_cache_seconds}, immutable"

  plug Plug.Static,
    at: @places_path,
    from: {__MODULE__, :places_dir, []},
    gzip: false,
    only_matching: [@places_file_prefix],
    cache_control_for_etags: "public, max-age=#{@places_cache_seconds}, immutable"

  plug Plug.Static,
    at: @places_path,
    from: {__MODULE__, :places_dir, []},
    gzip: false,
    only: [@places_manifest_name],
    cache_control_for_etags: "no-cache"

  plug Plug.Static,
    at: @places_path,
    from: {__MODULE__, :places_dir, []},
    gzip: false,
    only: [@places_notice_name],
    content_types: %{@places_notice_name => "text/plain; charset=utf-8"},
    cache_control_for_etags: "no-cache"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}
  plug Plug.Session, @session_options
  plug GobusgoWeb.Router

  @doc """
  Keeps the JSON media type of the response under an error status, for a
  body that is a JSON-RPC error and not problem details.
  """
  @spec keep_json_content_type(Plug.Conn.t()) :: Plug.Conn.t()
  def keep_json_content_type(conn), do: Plug.Conn.put_private(conn, @json_body_key, true)

  @doc "The directory the basemap files are served from."
  @spec basemap_dir() :: String.t()
  def basemap_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.basemap()
    dir
  end

  @doc "The directory the locally stored address shard files are served from."
  @spec addresses_dir() :: String.t()
  def addresses_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.addresses()
    dir
  end

  @doc "The directory the locally stored intersection files are served from."
  @spec intersections_dir() :: String.t()
  def intersections_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.intersections()
    dir
  end

  @doc "The directory the locally stored routing snapshot files are served from."
  @spec routing_dir() :: String.t()
  def routing_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.routing()
    dir
  end

  @doc "The directory the locally stored places files are served from."
  @spec places_dir() :: String.t()
  def places_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.places()
    dir
  end

  @doc "The directory the locally stored shared vehicle files are served from."
  @spec shared_vehicles_dir() :: String.t()
  def shared_vehicles_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.shared_vehicle_tiles()
    dir
  end

  @doc "The directory the locally stored tile archives are served from."
  @spec tiles_dir() :: String.t()
  def tiles_dir do
    {:ok, %{dir: dir}} = Gobusgo.Config.tiles()
    dir
  end

  @doc "The level a request is logged at, or `false` for a request that is not logged."
  @spec log_level(Plug.Conn.t()) :: Logger.level() | false
  def log_level(%Plug.Conn{request_path: @health_path}), do: false
  def log_level(%Plug.Conn{request_path: @readiness_path}), do: false
  def log_level(%Plug.Conn{}), do: :info

  defp problem_content_type(conn, _options) do
    Plug.Conn.register_before_send(conn, fn conn ->
      is_error = conn.status >= @error_status_min
      is_problem = is_error and not is_map_key(conn.private, @json_body_key)

      if is_problem do
        mark_problem(conn)
      else
        conn
      end
    end)
  end

  defp mark_problem(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [@json_content_type <> parameters] ->
        Plug.Conn.put_resp_header(conn, "content-type", @problem_content_type <> parameters)

      _other ->
        conn
    end
  end
end
