defmodule Gobusgo.OneBusAway.CompactSchedule do
  @moduledoc """
  The form a route's schedule on one service date is held in memory: the
  route's stops once, and each trip's stops as indexes into them, with the
  times and boarding flags of its stop times as binaries. Everything here is
  pure.

  A stop time held as a map takes about 510 bytes, and one held here about
  18, which is what lets a view hold the region's schedule: an estimated
  700,000 stop times a weekday, roughly 13 MB here against roughly 360 MB as
  maps (measured on the A Line on 2026-11-07).

  A trip's binaries hold one entry per stop time, in the order the trip
  serves them:

    * `stop_indexes`: an unsigned 16-bit big-endian index into the
      schedule's `stop_ids`.
    * `arrival_s` and `departure_s`: unsigned 32-bit big-endian seconds from
      the start of the service day.
    * `enabled_flags`: one byte, with bit 0 set where riders may leave and
      bit 1 set where riders may board.
  """

  alias Gobusgo.OneBusAway.RouteSchedules

  @index_max 0xFFFF
  @time_s_max 0xFFFFFFFF
  @arrival_enabled_bit 1
  @departure_enabled_bit 2

  @typedoc "One trip, its stop times packed into binaries."
  @type trip :: %{
          id: String.t(),
          direction_id: String.t(),
          headsign: String.t() | nil,
          block_id: String.t() | nil,
          service_id: String.t(),
          shape_id: String.t() | nil,
          stop_indexes: binary(),
          arrival_s: binary(),
          departure_s: binary(),
          enabled_flags: binary()
        }

  @typedoc """
  The schedule of one route on one service date. `stop_ids` is a tuple, so
  a stop index reads its identifier in constant time.
  """
  @type t :: %{
          route_id: String.t(),
          schedule_date_ms: integer(),
          service_ids: [String.t()],
          stop_ids: tuple(),
          stop_time_count: non_neg_integer(),
          trips: [trip()]
        }

  @typedoc "One trip with its stop times as lists, one entry per stop time in each."
  @type listed_trip :: %{
          id: String.t(),
          direction_id: String.t(),
          headsign: String.t() | nil,
          block_id: String.t() | nil,
          service_id: String.t(),
          shape_id: String.t() | nil,
          stop_indexes: [non_neg_integer()],
          arrival_s: [non_neg_integer()],
          departure_s: [non_neg_integer()],
          arrival_enabled: [boolean()],
          departure_enabled: [boolean()]
        }

  @type listed :: %{
          route_id: String.t(),
          schedule_date_ms: integer(),
          service_ids: [String.t()],
          stop_ids: [String.t()],
          trips: [listed_trip()]
        }

  @typedoc """
    * `:stop_count_exceeded` — the route has more stops than a 16-bit index
      reaches.
    * `{:length_mismatch, trip_id}` — a trip's lists differ in length, or
      are empty.
    * `{:index_out_of_range, trip_id}` — a trip names a stop index the
      route's stops do not have.
    * `{:time_out_of_range, trip_id}` — a trip has a time outside 32
      unsigned bits.
  """
  @type pack_error ::
          :stop_count_exceeded
          | {:length_mismatch, String.t()}
          | {:index_out_of_range, String.t()}
          | {:time_out_of_range, String.t()}

  @doc """
  Returns `schedule` as lists: the stops of every trip once, in the order
  the trips first serve them, and each trip's stop times as indexes into
  them.
  """
  @spec list(RouteSchedules.schedule()) :: listed()
  def list(%{trips: trips} = schedule) do
    stop_ids =
      for trip <- trips, stop_time <- trip.stop_times, uniq: true, do: stop_time.stop_id

    index_by_stop_id = stop_ids |> Enum.with_index() |> Map.new()

    %{
      route_id: schedule.route_id,
      schedule_date_ms: schedule.schedule_date_ms,
      service_ids: schedule.service_ids,
      stop_ids: stop_ids,
      trips: Enum.map(trips, &listed_trip(&1, index_by_stop_id))
    }
  end

  defp listed_trip(%{stop_times: stop_times} = trip, index_by_stop_id) do
    trip
    |> Map.delete(:stop_times)
    |> Map.merge(%{
      stop_indexes: Enum.map(stop_times, &Map.fetch!(index_by_stop_id, &1.stop_id)),
      arrival_s: Enum.map(stop_times, & &1.arrival_s),
      departure_s: Enum.map(stop_times, & &1.departure_s),
      arrival_enabled: Enum.map(stop_times, & &1.arrival_enabled),
      departure_enabled: Enum.map(stop_times, & &1.departure_enabled)
    })
  end

  @doc """
  Returns `listed` packed into binaries, or the first rule it breaks.
  """
  @spec pack(listed()) :: {:ok, t()} | {:error, pack_error()}
  def pack(%{stop_ids: stop_ids, trips: trips} = listed) do
    stop_count = length(stop_ids)

    if stop_count <= @index_max + 1 do
      packed = Enum.map(trips, &pack_trip(&1, stop_count))

      case Enum.find(packed, &match?({:error, _reason}, &1)) do
        nil ->
          trips = Enum.map(packed, fn {:ok, trip} -> trip end)

          {:ok,
           %{
             route_id: listed.route_id,
             schedule_date_ms: listed.schedule_date_ms,
             service_ids: listed.service_ids,
             stop_ids: List.to_tuple(stop_ids),
             stop_time_count: Enum.sum_by(trips, &byte_size(&1.enabled_flags)),
             trips: trips
           }}

        failure ->
          failure
      end
    else
      {:error, :stop_count_exceeded}
    end
  end

  defp pack_trip(%{id: id} = trip, stop_count) do
    lists = [
      trip.stop_indexes,
      trip.arrival_s,
      trip.departure_s,
      trip.arrival_enabled,
      trip.departure_enabled
    ]

    lengths = Enum.map(lists, &length/1)
    times = trip.arrival_s ++ trip.departure_s

    cond do
      Enum.uniq(lengths) != [hd(lengths)] or hd(lengths) == 0 ->
        {:error, {:length_mismatch, id}}

      Enum.any?(trip.stop_indexes, &(&1 < 0 or &1 >= stop_count)) ->
        {:error, {:index_out_of_range, id}}

      Enum.any?(times, &(&1 < 0 or &1 > @time_s_max)) ->
        {:error, {:time_out_of_range, id}}

      true ->
        enabled = Enum.zip(trip.arrival_enabled, trip.departure_enabled)

        {:ok,
         %{
           id: id,
           direction_id: trip.direction_id,
           headsign: trip.headsign,
           block_id: trip.block_id,
           service_id: trip.service_id,
           shape_id: trip.shape_id,
           stop_indexes: for(index <- trip.stop_indexes, into: <<>>, do: <<index::16>>),
           arrival_s: for(time_s <- trip.arrival_s, into: <<>>, do: <<time_s::32>>),
           departure_s: for(time_s <- trip.departure_s, into: <<>>, do: <<time_s::32>>),
           enabled_flags: for(pair <- enabled, into: <<>>, do: <<enabled_flags(pair)>>)
         }}
    end
  end

  defp enabled_flags({arrival_enabled, departure_enabled}) do
    flag(arrival_enabled, @arrival_enabled_bit) + flag(departure_enabled, @departure_enabled_bit)
  end

  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0

  @typedoc """
  Two consecutive stop times of a trip: `sequence` is the position of the
  first in the trip, the stops are indexes into the schedule's `stop_ids`,
  the departure is the first stop's and the arrival the second's, and
  `boarding` and `alighting` say whether riders may board at the first and
  leave at the second.
  """
  @type hop :: %{
          sequence: non_neg_integer(),
          from_index: non_neg_integer(),
          to_index: non_neg_integer(),
          departure_s: non_neg_integer(),
          arrival_s: non_neg_integer(),
          boarding: boolean(),
          alighting: boolean()
        }

  @doc """
  Reduces each hop of `trip`, every two consecutive stop times in the order
  the trip serves them, with `fun`, starting from `acc`. The hops are read
  from the trip's binaries one at a time, so a date's trips are reduced with
  no list of their stop times.
  """
  @spec reduce_hops(trip(), acc, (hop(), acc -> acc)) :: acc when acc: term()
  def reduce_hops(%{enabled_flags: enabled_flags} = trip, acc, fun) when is_function(fun, 2) do
    hop_count = byte_size(enabled_flags) - 1
    Enum.reduce(0..(hop_count - 1)//1, acc, &fun.(hop(trip, &1), &2))
  end

  defp hop(trip, sequence) do
    index_bytes = sequence * 2
    departure_bytes = sequence * 4
    arrival_bytes = departure_bytes + 4

    <<_before::binary-size(^index_bytes), from_index::16, to_index::16, _rest::binary>> =
      trip.stop_indexes

    <<_before::binary-size(^departure_bytes), departure_s::32, _rest::binary>> = trip.departure_s
    <<_before::binary-size(^arrival_bytes), arrival_s::32, _rest::binary>> = trip.arrival_s

    <<_before::binary-size(^sequence), from_flags::8, to_flags::8, _rest::binary>> =
      trip.enabled_flags

    %{
      sequence: sequence,
      from_index: from_index,
      to_index: to_index,
      departure_s: departure_s,
      arrival_s: arrival_s,
      boarding: Bitwise.band(from_flags, @departure_enabled_bit) != 0,
      alighting: Bitwise.band(to_flags, @arrival_enabled_bit) != 0
    }
  end

  @doc """
  Returns the stop times of `trip`, a trip of `schedule`, as maps, in the
  order the trip serves them.
  """
  @spec stop_times(t(), trip()) :: [RouteSchedules.stop_time()]
  def stop_times(%{stop_ids: stop_ids}, trip) do
    indexes = for <<index::16 <- trip.stop_indexes>>, do: index
    arrivals = for <<time_s::32 <- trip.arrival_s>>, do: time_s
    departures = for <<time_s::32 <- trip.departure_s>>, do: time_s
    flags = for <<flags::8 <- trip.enabled_flags>>, do: flags

    for {index, arrival_s, departure_s, flags} <- Enum.zip([indexes, arrivals, departures, flags]) do
      %{
        stop_id: elem(stop_ids, index),
        arrival_s: arrival_s,
        departure_s: departure_s,
        arrival_enabled: Bitwise.band(flags, @arrival_enabled_bit) != 0,
        departure_enabled: Bitwise.band(flags, @departure_enabled_bit) != 0
      }
    end
  end
end
