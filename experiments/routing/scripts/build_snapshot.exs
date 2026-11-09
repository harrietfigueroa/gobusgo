# Builds the routing snapshots of the benchmark from the stored responses
# under a data directory, through the application's own rebuilds and build:
# the agency view takes the newest stored agencies-with-coverage response
# of the day, the route rebuild fills the route view and the stop view from
# the stored routes-for-agency and stops-for-route
# responses, the route schedule rebuild fills the schedule view from the
# stored schedule-for-route responses, and one snapshot build writes the
# files and prints the manifest.
#
#   MIX_ENV=test mix run --no-start experiments/routing/scripts/build_snapshot.exs \
#     <data directory> <output directory> <UTC time, ISO 8601>
#
# The time decides which stored days and service dates are read, as it does
# after a start. The output directory receives routing/snapshots/... and
# manifest.json.

alias Gobusgo.OneBusAway.{
  AgencyBatch,
  AgencyView,
  FetchView,
  RouteBatch,
  RoutePathBatch,
  RouteRebuild,
  RouteScheduleRebuild,
  RouteScheduleView,
  StopView
}

[data_text, output_text, time_text] = System.argv()
data_dir = Path.expand(data_text)
output_dir = Path.expand(output_text)
{:ok, now, 0} = DateTime.from_iso8601(time_text)
Logger.configure(level: :info)
{:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _pubsub} = Phoenix.PubSub.Supervisor.start_link(name: BenchmarkPubSub)

{:ok, _routes} =
  FetchView.start_link(
    name: BenchmarkRouteView,
    pubsub: BenchmarkPubSub,
    records: RouteBatch.Records,
    id_count_max: 64
  )

{:ok, _paths} =
  FetchView.start_link(
    name: BenchmarkRoutePathView,
    pubsub: BenchmarkPubSub,
    records: RoutePathBatch.Records,
    id_count_max: 5_000
  )

{:ok, _stops} =
  StopView.start_link(
    name: BenchmarkStopView,
    pubsub: BenchmarkPubSub,
    route_count_max: 5_000,
    stop_count_max: 100_000
  )

{:ok, _schedules} =
  RouteScheduleView.start_link(name: BenchmarkScheduleView, route_count_max: 5_000)

{:ok, _agencies} = AgencyView.start_link(name: BenchmarkAgencyView, pubsub: BenchmarkPubSub)
{:ok, _snapshots} = Gobusgo.Routing.Snapshots.start_link(name: BenchmarkSnapshots)

subscribers = %{
  "oba.agencies-with-coverage.state" => {AgencyView, :apply_records, [BenchmarkAgencyView]},
  "oba.routes.state" =>
    {FetchView, :apply_records_to_each, [[BenchmarkRouteView, BenchmarkRoutePathView]]},
  "oba.stops.state" => {StopView, :apply_records, [BenchmarkStopView]},
  "oba.schedules.state" => {RouteScheduleView, :apply_records, [BenchmarkScheduleView]}
}

rebuild_options = [
  now: fn -> now end,
  read_options: [backend: Gobusgo.Reader.LocalFile, base_dir: data_dir],
  publish_options: [backend: Gobusgo.Publisher.InProcess, subscribers: subscribers]
]

agency_prefix = "raw/oba/agencies-with-coverage/dt=#{Date.to_iso8601(DateTime.to_date(now))}/"

{:ok, %{destinations: [agency_destination]}} =
  Gobusgo.Reader.discover(
    %{prefix: agency_prefix, limit: 1, order: :descending, cursor: nil},
    Keyword.fetch!(rebuild_options, :read_options)
  )

IO.inspect(
  AgencyBatch.process(agency_destination,
    read_options: Keyword.fetch!(rebuild_options, :read_options),
    publish_options: Keyword.fetch!(rebuild_options, :publish_options)
  ),
  label: "agency batch"
)

IO.inspect(RouteRebuild.run(rebuild_options), label: "route rebuild")
IO.inspect(RouteScheduleRebuild.run(rebuild_options), label: "route schedule rebuild")

{elapsed_us, built} =
  :timer.tc(fn ->
    Gobusgo.Routing.Snapshots.Build.run(
      server: BenchmarkSnapshots,
      schedule_view: BenchmarkScheduleView,
      stop_view: BenchmarkStopView,
      route_view: BenchmarkRouteView,
      agency_view: BenchmarkAgencyView,
      clock: fn -> now end,
      write_options: [backend: Gobusgo.Writer.LocalFile, base_dir: output_dir]
    )
  end)

IO.inspect(built, label: "snapshot build")
IO.puts("snapshot build: #{div(elapsed_us, 1_000)} ms")
manifest = Gobusgo.Routing.Snapshots.manifest(BenchmarkSnapshots)
File.write!(Path.join(output_dir, "manifest.json"), Gobusgo.CanonicalJson.encode(manifest))
