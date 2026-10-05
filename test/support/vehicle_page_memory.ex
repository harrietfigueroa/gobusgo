defmodule Gobusgo.Test.VehiclePageMemory do
  @fetch_interval_seconds 5
  @report_age_ms 20_000
  @first_fetched_at ~U[2026-10-05 00:40:44Z]

  # The vehicles each agency returned in the fetch cycle stored at
  # 2026-10-05T00:40:44Z, a Sunday evening in the service area.
  @fetch_profile [
    %{agency_id: "1", vehicle_count: 1052},
    %{agency_id: "19", vehicle_count: 0},
    %{agency_id: "20", vehicle_count: 11},
    %{agency_id: "23", vehicle_count: 10},
    %{agency_id: "29", vehicle_count: 195},
    %{agency_id: "3", vehicle_count: 99},
    %{agency_id: "40", vehicle_count: 181},
    %{agency_id: "51", vehicle_count: 0},
    %{agency_id: "6289", vehicle_count: 0},
    %{agency_id: "95", vehicle_count: 17},
    %{agency_id: "96", vehicle_count: 0},
    %{agency_id: "97", vehicle_count: 76}
  ]

  @moduledoc """
  What the memory measurements of the vehicle page share: synthetic fetches
  that fill a vehicle view, and readings of the memory a process and a table
  hold.

  A synthetic vehicle supplies every field, so a fetch of them is at least
  as large as a fetch of as many real vehicles. Fetches follow each other by
  sequence, #{@fetch_interval_seconds} seconds apart, and a vehicle stands
  at another position in each.
  """

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @grid_column_count 40
  @grid_step_degrees 0.02
  @sequence_step_degrees 0.0001
  @grid_south_degrees 47.2
  @grid_west_degrees -122.7
  @degrees_per_turn 360
  @trip_number_first 600_000_000
  @route_number_first 100
  @route_count 50
  @random_bit_count 80

  @type fetch :: %{
          agency_id: String.t(),
          vehicle_count: non_neg_integer(),
          sequence: non_neg_integer()
        }

  @type process_memory :: %{
          memory_bytes: non_neg_integer(),
          heap_bytes: non_neg_integer(),
          binary_bytes: non_neg_integer()
        }

  @doc """
  Returns the vehicle count of each agency in one fetch cycle of the source,
  in agency identifier order.
  """
  @spec fetch_profile() :: [%{agency_id: String.t(), vehicle_count: non_neg_integer()}]
  def fetch_profile, do: @fetch_profile

  @doc """
  Applies to `view` a complete fetch of `fetch.agency_id` that holds
  `fetch.vehicle_count` vehicles, and returns once the view holds it. A
  fetch of a later `fetch.sequence` replaces the agency's earlier one.
  """
  @spec apply_fetch(atom(), fetch()) :: :ok
  def apply_fetch(view, %{agency_id: agency_id, vehicle_count: vehicle_count, sequence: sequence})
      when is_atom(view) and is_binary(agency_id) and is_integer(vehicle_count) and
             is_integer(sequence) do
    fetched_at = DateTime.add(@first_fetched_at, sequence * @fetch_interval_seconds, :second)
    context = %{agency_id: agency_id, sequence: sequence, fetched_at: fetched_at}

    %{vehicles: records, manifest: manifest} =
      Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/vehicles-for-agency/agency=#{agency_id}/#{sequence}.json",
        fetched_at: fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(context),
        vehicles: for(index <- 0..(vehicle_count - 1)//1, do: vehicle(index, context))
      })

    (records ++ [manifest])
    |> Enum.map(& &1.value)
    |> Enum.chunk_every(Publisher.record_count_max())
    |> Enum.each(fn values -> :ok = VehicleView.apply_records(view, values) end)
  end

  @doc """
  Returns the memory of the process `pid`: all of it, its heaps, and the
  binaries outside its heaps that it refers to, each counted once. Other
  processes can refer to the same binaries.
  """
  @spec process_memory(pid()) :: process_memory()
  def process_memory(pid) when is_pid(pid) do
    [memory: memory_bytes, total_heap_size: heap_words, binary: binaries] =
      Process.info(pid, [:memory, :total_heap_size, :binary])

    binary_bytes =
      binaries
      |> Enum.uniq_by(fn {id, _size, _reference_count} -> id end)
      |> Enum.sum_by(fn {_id, size, _reference_count} -> size end)

    %{
      memory_bytes: memory_bytes,
      heap_bytes: heap_words * :erlang.system_info(:wordsize),
      binary_bytes: binary_bytes
    }
  end

  @doc """
  Returns the bytes the table `table` holds. Binaries outside the table that
  its entries refer to are not counted.
  """
  @spec table_memory_bytes(atom()) :: non_neg_integer()
  def table_memory_bytes(table) when is_atom(table) do
    :ets.info(table, :memory) * :erlang.system_info(:wordsize)
  end

  @doc """
  Returns, over every vehicle of every current fetch of `view`, the bytes of
  the vehicle identifiers and the bytes of the binaries those identifiers
  keep alive. The two are equal when each identifier is a binary of its own.
  """
  @spec identifier_retention(atom()) :: %{
          identifier_bytes: non_neg_integer(),
          referenced_bytes: non_neg_integer()
        }
  def identifier_retention(view) when is_atom(view) do
    identifiers =
      for %{vehicles: vehicles} <- VehicleView.current(view),
          {_id, %{"id" => identifier}} <- vehicles do
        identifier
      end

    %{
      identifier_bytes: Enum.sum_by(identifiers, &byte_size/1),
      referenced_bytes: Enum.sum_by(identifiers, &:binary.referenced_byte_size/1)
    }
  end

  defp request_id(%{agency_id: agency_id, sequence: sequence, fetched_at: fetched_at}) do
    RequestId.build(%{
      unix_ms: DateTime.to_unix(fetched_at, :millisecond),
      random: <<:erlang.phash2({agency_id, sequence})::size(@random_bit_count)>>
    })
  end

  defp vehicle(index, %{agency_id: agency_id, sequence: sequence, fetched_at: fetched_at}) do
    report_time_ms = DateTime.to_unix(fetched_at, :millisecond) - @report_age_ms
    row_index = div(index, @grid_column_count)
    column_index = rem(index, @grid_column_count)
    lat = @grid_south_degrees + row_index * @grid_step_degrees
    lon = @grid_west_degrees + column_index * @grid_step_degrees
    orientation = rem(index + sequence, @degrees_per_turn) * 1.0
    route_number = @route_number_first + rem(index, @route_count)

    %{
      id: "#{agency_id}_#{index}",
      active_trip_id: "#{agency_id}_#{@trip_number_first + index}",
      route_id: "#{agency_id}_#{route_number}",
      route_short_name: "#{route_number}",
      route_long_name: "Downtown Seattle - University District",
      trip_headsign: "University District",
      position: %{lat: lat + sequence * @sequence_step_degrees, lon: lon},
      orientation: orientation,
      last_known_location: %{lat: lat, lon: lon},
      last_known_orientation: orientation,
      last_update_time_ms: report_time_ms,
      last_location_update_time_ms: report_time_ms,
      predicted: true
    }
  end
end
