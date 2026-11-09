defmodule Gobusgo.StartMemory.Fixture do
  @agency_count 12
  @route_count 390
  @grid_side_count 120
  @grid_spacing_m 250
  @center_latitude 47.6062
  @center_longitude -122.3321
  @meters_per_degree_latitude 111_320
  @route_stop_count_min 30
  @route_stop_count_max 90
  # A heading is one of the eight neighbors of a grid cell; a turn draw of
  # the last two of eight turns one eighth right or left.
  @heading_count 8
  @turn_right_draw 6
  @turn_left_draw 7
  # The two held service dates of production on 2026-11-08: the routes with
  # service on each and the connections of each date's own trips.
  @first_date_route_indexes 0..289//1
  @second_date_route_indexes 51..389//1
  @first_date_connection_count 440_000
  @second_date_connection_count 650_000
  @trip_count_min 2
  @route_weight_min 0.4
  @route_weight_span 1.2

  # Service runs from 04:30 to a last departure at 25:00, so the trips of
  # the late evening run past midnight into the next date.
  @first_departure_s 16_200
  @last_departure_s 90_000
  @hop_s_min 60
  @hop_s_span 91
  @dwell_s_max 20
  # The synthetic agencies keep Pacific Standard Time, eight hours behind UTC.
  @service_day_offset_s 8 * 60 * 60

  @host "onebusaway.invalid"
  # A step that spreads the routes' colors over the six-digit range.
  @color_step 40_503
  @color_count 0x1000000
  @color_digit_count 6
  @envelope_version 2
  @seed {2026, 11, 8}

  @moduledoc """
  Stored OneBusAway responses of a synthetic network sized like
  production's on 2026-11-08, for measuring what a start of the application
  holds: #{@agency_count} agencies, #{@route_count} routes with a path each
  over stops on a grid of #{@grid_side_count} by #{@grid_side_count} cells
  #{@grid_spacing_m} m apart, and the schedules of
  #{Enum.count(@first_date_route_indexes)} routes on a first service date and
  #{Enum.count(@second_date_route_indexes)} on the day after, about
  #{@first_date_connection_count} and #{@second_date_connection_count}
  connections of each date's own trips.

  Everything here is pure, and the network is the same for every date: the
  responses are a function of `date` alone, which names the UTC day they
  were fetched on and the first service date. Each response is built in the
  stored form of its dataset's recorder after its data passes the parser of
  its requester, so a stored response is one the application reads back.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.OneBusAway.Routes
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.Polyline
  alias Gobusgo.RequestId

  @type route :: %{
          index: non_neg_integer(),
          id: String.t(),
          agency_id: String.t(),
          stop_cells: [non_neg_integer(), ...],
          hops_s: [pos_integer()],
          dwells_s: [non_neg_integer()],
          weight: float()
        }

  @type summary :: %{
          agency_count: pos_integer(),
          route_count: pos_integer(),
          stop_count: pos_integer(),
          schedules: [
            %{
              service_date: Date.t(),
              route_count: pos_integer(),
              trip_count: pos_integer(),
              connection_count: pos_integer()
            }
          ]
        }

  @doc """
  Every stored response of the fixture fetched on `date`: the routes of each
  agency, the stops and path of each route, and the schedules of both
  service dates, lazily, each built when it is taken.
  """
  @spec responses(Date.t()) :: Enumerable.t(RawResponse.t())
  def responses(%Date{} = date) do
    routes = routes()
    route_ids_by_cell = route_ids_by_cell(routes)
    fetched_at_start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

    jobs =
      Enum.map(agency_ids(), &{:agency, &1}) ++
        Enum.map(routes, &{:route_path, &1}) ++ schedule_jobs(routes, date)

    jobs
    |> Stream.with_index()
    |> Stream.map(fn {job, ordinal} ->
      fetched_at = DateTime.add(fetched_at_start, ordinal, :second)

      build(job, %{
        routes: routes,
        route_ids_by_cell: route_ids_by_cell,
        fetched_at: fetched_at,
        ordinal: ordinal
      })
    end)
  end

  @doc "The counts the responses of `date` hold, computed without building them."
  @spec summary(Date.t()) :: summary()
  def summary(%Date{} = date) do
    routes = routes()

    schedules =
      for {service_date, indexes, connection_count} <- service_dates(date) do
        planned = for index <- indexes, do: Enum.at(routes, index)
        trip_counts = trip_counts(planned, connection_count)

        %{
          service_date: service_date,
          route_count: length(planned),
          trip_count: Enum.sum(Map.values(trip_counts)),
          connection_count:
            Enum.sum(
              for route <- planned, do: trip_counts[route.id] * (length(route.stop_cells) - 1)
            )
        }
      end

    %{
      agency_count: @agency_count,
      route_count: @route_count,
      stop_count: routes |> Enum.flat_map(& &1.stop_cells) |> Enum.uniq() |> length(),
      schedules: schedules
    }
  end

  @doc "The routes of the network, each with its stops in the order of its first direction."
  @spec routes() :: [route()]
  def routes do
    state = :rand.seed_s(:exsss, @seed)

    {routes, _state} =
      Enum.map_reduce(0..(@route_count - 1)//1, state, fn index, state ->
        route(index, state)
      end)

    Assert.condition(length(routes) == @route_count, "the network holds #{@route_count} routes")
    routes
  end

  defp route(index, state) do
    {stop_count, state} = uniform_between(state, @route_stop_count_min, @route_stop_count_max)
    {start_cell, state} = uniform_between(state, 0, @grid_side_count * @grid_side_count - 1)
    {step_index, state} = uniform_between(state, 0, @heading_count - 1)

    {stop_cells, state} =
      walk(%{cells: [start_cell], step_index: step_index, stop_count: stop_count}, state)

    hop_count = length(stop_cells) - 1

    {hops_s, state} =
      Enum.map_reduce(1..hop_count//1, state, fn _hop, state ->
        uniform_between(state, @hop_s_min, @hop_s_min + @hop_s_span - 1)
      end)

    {dwells_s, state} =
      Enum.map_reduce(stop_cells, state, fn _cell, state ->
        uniform_between(state, 0, @dwell_s_max)
      end)

    {weight_fraction, state} = :rand.uniform_s(state)
    agency_index = rem(index, @agency_count)
    agency_id = Enum.at(agency_ids(), agency_index)

    route = %{
      index: index,
      id: "#{agency_id}_#{100_000 + index}",
      agency_id: agency_id,
      stop_cells: stop_cells,
      hops_s: hops_s,
      dwells_s: dwells_s,
      weight: @route_weight_min + @route_weight_span * weight_fraction
    }

    Assert.condition(length(stop_cells) >= 2, "a route serves at least two stops")
    {route, state}
  end

  # A route walks the grid one cell at a time, keeping its heading three
  # times in four and turning by one eighth otherwise. It never serves a
  # cell twice, and ends early where every heading it may take is used or
  # off the grid.
  defp walk(%{cells: cells, stop_count: stop_count}, state) when length(cells) >= stop_count do
    {Enum.reverse(cells), state}
  end

  defp walk(%{cells: [cell | _rest] = cells, step_index: step_index} = walk, state) do
    {turn_draw, state} = uniform_between(state, 0, @heading_count - 1)

    preferred =
      case turn_draw do
        @turn_right_draw -> rem(step_index + 1, @heading_count)
        @turn_left_draw -> rem(step_index + @heading_count - 1, @heading_count)
        _keep -> step_index
      end

    candidates =
      for offset <- [0, 1, @heading_count - 1, 2, @heading_count - 2],
          next_step_index = rem(preferred + offset, @heading_count),
          {:ok, next_cell} <- [step(cell, next_step_index)],
          next_cell not in cells,
          do: {next_step_index, next_cell}

    case candidates do
      [{next_step_index, next_cell} | _rest] ->
        walk(%{walk | cells: [next_cell | cells], step_index: next_step_index}, state)

      [] ->
        {Enum.reverse(cells), state}
    end
  end

  @steps [{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}]

  defp step(cell, step_index) do
    {column_step, row_step} = Enum.at(@steps, step_index)
    column = rem(cell, @grid_side_count) + column_step
    row = div(cell, @grid_side_count) + row_step
    column_inside = column >= 0 and column < @grid_side_count
    row_inside = row >= 0 and row < @grid_side_count

    case column_inside and row_inside do
      true -> {:ok, row * @grid_side_count + column}
      false -> :outside
    end
  end

  defp uniform_between(state, low, high) do
    Assert.condition(low <= high, "range #{low}..#{high} must not be empty")
    {draw, state} = :rand.uniform_s(high - low + 1, state)
    {low + draw - 1, state}
  end

  defp agency_ids, do: for(index <- 1..@agency_count//1, do: Integer.to_string(index))

  defp route_ids_by_cell(routes) do
    routes
    |> Enum.flat_map(fn route -> for cell <- route.stop_cells, do: {cell, route.id} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {cell, route_ids} -> {cell, route_ids |> Enum.uniq() |> Enum.sort()} end)
  end

  defp service_dates(date) do
    [
      {date, @first_date_route_indexes, @first_date_connection_count},
      {Date.add(date, 1), @second_date_route_indexes, @second_date_connection_count}
    ]
  end

  defp schedule_jobs(routes, date) do
    for {{service_date, indexes, connection_count}, date_index} <-
          Enum.with_index(service_dates(date)),
        planned = for(index <- indexes, do: Enum.at(routes, index)),
        trip_counts = trip_counts(planned, connection_count),
        route <- planned do
      {:schedule,
       %{
         route: route,
         service_date: service_date,
         date_index: date_index,
         trip_count: trip_counts[route.id]
       }}
    end
  end

  # Each route's share of the date's connections follows its weight, in
  # whole trips of its own length.
  defp trip_counts(planned, connection_count) do
    weight_total = planned |> Enum.map(& &1.weight) |> Enum.sum()

    Map.new(planned, fn route ->
      hop_count = length(route.stop_cells) - 1
      share = connection_count * route.weight / weight_total
      {route.id, max(@trip_count_min, round(share / hop_count))}
    end)
  end

  defp build({:agency, agency_id}, context) do
    routes = for route <- context.routes, route.agency_id == agency_id, do: route_entry(route)
    data = %{"limitExceeded" => false, "list" => routes, "references" => empty_references()}
    {:ok, parsed} = Routes.parse(data, agency_id)

    response =
      response(%{data: data, fetched_at: context.fetched_at})
      |> Map.merge(%{agency_id: agency_id, routes: parsed})

    RawRouteResponse.build(%{response: response, request_id: request_id(context)})
  end

  defp build({:route_path, route}, context) do
    data = route_path_data(route, context.route_ids_by_cell)
    {:ok, route_path} = RoutePaths.parse(data, route.id)

    response =
      response(%{data: data, fetched_at: context.fetched_at})
      |> Map.merge(%{route_id: route.id, route_path: route_path})

    RawRoutePathResponse.build(%{response: response, request_id: request_id(context)})
  end

  defp build({:schedule, schedule}, context) do
    data = schedule_data(schedule)
    {:ok, parsed} = RouteSchedules.parse(data, schedule.route.id)

    response =
      response(%{data: data, fetched_at: context.fetched_at})
      |> Map.merge(%{
        route_id: schedule.route.id,
        service_date: schedule.service_date,
        schedule: parsed
      })

    RawRouteScheduleResponse.build(%{response: response, request_id: request_id(context)})
  end

  defp response(%{data: data, fetched_at: fetched_at}) do
    %{
      envelope: %{
        "code" => 200,
        "currentTime" => DateTime.to_unix(fetched_at, :millisecond),
        "data" => data,
        "text" => "OK",
        "version" => @envelope_version
      },
      fetched_at: fetched_at,
      host: @host,
      http_status: 200,
      method: "GET"
    }
  end

  defp request_id(%{fetched_at: fetched_at, ordinal: ordinal}) do
    RequestId.build(%{
      unix_ms: DateTime.to_unix(fetched_at, :millisecond),
      random: <<ordinal::80>>
    })
  end

  defp empty_references do
    %{
      "agencies" => [],
      "routes" => [],
      "situations" => [],
      "stopTimes" => [],
      "stops" => [],
      "trips" => []
    }
  end

  defp route_entry(route) do
    %{
      "agencyId" => route.agency_id,
      "color" => route_color(route),
      "description" => "",
      "id" => route.id,
      "longName" => "Synthetic route #{route.index}",
      "shortName" => Integer.to_string(route.index + 1),
      "textColor" => "FFFFFF",
      "type" => 3,
      "url" => ""
    }
  end

  # One route in five has no color, as some agencies supply none.
  defp route_color(%{index: index}) when rem(index, 5) == 0, do: ""

  defp route_color(%{index: index}) do
    index
    |> Kernel.*(@color_step)
    |> rem(@color_count)
    |> Integer.to_string(16)
    |> String.pad_leading(@color_digit_count, "0")
  end

  defp route_path_data(route, route_ids_by_cell) do
    directions = directions(route)
    stop_ids = for cell <- route.stop_cells, do: stop_id(cell)

    %{
      "entry" => %{
        "routeId" => route.id,
        "stopIds" => Enum.sort(stop_ids),
        "polylines" => [polyline(route.stop_cells)],
        "stopGroupings" => [
          %{
            "type" => "direction",
            "ordered" => true,
            "stopGroups" =>
              for {direction_id, cells} <- directions do
                headsign = headsign(route, cells)

                %{
                  "id" => direction_id,
                  "name" => %{"name" => headsign, "names" => [headsign], "type" => "destination"},
                  "stopIds" => Enum.map(cells, &stop_id/1),
                  "polylines" => [polyline(cells)],
                  "subGroups" => []
                }
              end
          }
        ]
      },
      "references" =>
        Map.put(
          empty_references(),
          "stops",
          for(cell <- route.stop_cells, do: stop_reference(cell, route_ids_by_cell))
        )
    }
  end

  defp directions(route), do: [{"0", route.stop_cells}, {"1", Enum.reverse(route.stop_cells)}]

  defp headsign(route, cells), do: "Route #{route.index + 1} to stop #{List.last(cells)}"

  defp polyline(cells) do
    points = cells |> Enum.map(&point/1) |> Polyline.encode()
    %{"length" => length(cells), "levels" => "", "points" => points}
  end

  defp point(cell) do
    column = rem(cell, @grid_side_count) - div(@grid_side_count, 2)
    row = div(cell, @grid_side_count) - div(@grid_side_count, 2)
    latitude = @center_latitude + row * @grid_spacing_m / @meters_per_degree_latitude
    longitude_scale = @meters_per_degree_latitude * :math.cos(@center_latitude * :math.pi() / 180)
    longitude = @center_longitude + column * @grid_spacing_m / longitude_scale
    [Float.round(longitude, 6), Float.round(latitude, 6)]
  end

  defp stop_id(cell), do: "1_#{cell}"

  defp stop_reference(cell, route_ids_by_cell) do
    [longitude, latitude] = point(cell)

    %{
      "code" => Integer.to_string(cell),
      "direction" => Enum.at(["N", "E", "S", "W"], rem(cell, 4)),
      "id" => stop_id(cell),
      "lat" => latitude,
      "locationType" => 0,
      "lon" => longitude,
      "name" => "Synthetic stop #{cell}",
      "parent" => "",
      "routeIds" => Map.fetch!(route_ids_by_cell, cell),
      "wheelchairBoarding" => "UNKNOWN"
    }
  end

  defp schedule_data(%{
         route: route,
         service_date: service_date,
         date_index: date_index,
         trip_count: trip_count
       }) do
    service_id = "#{route.agency_id}_service_#{date_index}"
    service_day_start = DateTime.new!(service_date, ~T[00:00:00], "Etc/UTC")

    schedule_date_ms =
      service_day_start
      |> DateTime.add(@service_day_offset_s, :second)
      |> DateTime.to_unix(:millisecond)

    trips =
      for trip_index <- 0..(trip_count - 1)//1 do
        {direction_id, cells} = Enum.at(directions(route), rem(trip_index, 2))
        hops_s = hops_in_direction(route, direction_id)

        first_departure_s =
          @first_departure_s +
            div(trip_index * (@last_departure_s - @first_departure_s), trip_count)

        %{
          id: "#{route.id}_#{date_index}_#{trip_index}",
          direction_id: direction_id,
          headsign: headsign(route, cells),
          stop_times:
            stop_times(%{
              cells: cells,
              hops_s: hops_s,
              dwells_s: route.dwells_s,
              first_departure_s: first_departure_s
            })
        }
      end

    %{
      "entry" => %{
        "routeId" => route.id,
        "scheduleDate" => schedule_date_ms,
        "serviceIds" => [service_id],
        "stopTripGroupings" =>
          for {direction_id, cells} <- directions(route) do
            of_direction = for trip <- trips, trip.direction_id == direction_id, do: trip

            %{
              "directionId" => direction_id,
              "stopIds" => Enum.map(cells, &stop_id/1),
              "tripHeadsigns" => [headsign(route, cells)],
              "tripIds" => Enum.map(of_direction, & &1.id),
              "tripsWithStopTimes" =>
                for trip <- of_direction do
                  %{
                    "tripId" => trip.id,
                    "stopTimes" =>
                      for(
                        stop_time <- trip.stop_times,
                        do:
                          stop_time_entry(stop_time, %{trip_id: trip.id, service_id: service_id})
                      )
                  }
                end
            }
          end
      },
      "references" =>
        Map.put(
          empty_references(),
          "trips",
          for(trip <- trips, do: trip_reference(trip, %{route: route, service_id: service_id}))
        )
    }
  end

  defp hops_in_direction(route, "0"), do: route.hops_s
  defp hops_in_direction(route, "1"), do: Enum.reverse(route.hops_s)

  defp stop_times(%{
         cells: cells,
         hops_s: hops_s,
         dwells_s: dwells_s,
         first_departure_s: first_departure_s
       }) do
    stop_count = length(cells)
    last_index = stop_count - 1

    {stop_times, _time_s} =
      cells
      |> Enum.zip(dwells_s)
      |> Enum.zip([0 | hops_s])
      |> Enum.with_index()
      |> Enum.map_reduce(first_departure_s, fn {{{cell, dwell_s}, hop_s}, stop_index}, time_s ->
        arrival_s = time_s + hop_s
        departure_s = arrival_s + dwell_s

        stop_time = %{
          stop_id: stop_id(cell),
          arrival_s: arrival_s,
          departure_s: departure_s,
          arrival_enabled: stop_index > 0,
          departure_enabled: stop_index < last_index
        }

        {stop_time, departure_s}
      end)

    Assert.condition(
      length(stop_times) == stop_count,
      "a trip stops at each of its #{stop_count} stops"
    )

    stop_times
  end

  defp stop_time_entry(stop_time, %{trip_id: trip_id, service_id: service_id}) do
    %{
      "arrivalEnabled" => stop_time.arrival_enabled,
      "arrivalTime" => stop_time.arrival_s,
      "departureEnabled" => stop_time.departure_enabled,
      "departureTime" => stop_time.departure_s,
      "serviceId" => service_id,
      "stopHeadsign" => "",
      "stopId" => stop_time.stop_id,
      "tripId" => trip_id
    }
  end

  defp trip_reference(trip, %{route: route, service_id: service_id}) do
    %{
      "blockId" => "",
      "directionId" => trip.direction_id,
      "id" => trip.id,
      "peakOffpeak" => 0,
      "routeId" => route.id,
      "routeShortName" => "",
      "serviceId" => service_id,
      "shapeId" => "#{route.id}_shape_#{trip.direction_id}",
      "timeZone" => "",
      "tripHeadsign" => trip.headsign,
      "tripShortName" => ""
    }
  end
end
