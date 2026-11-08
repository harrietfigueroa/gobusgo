defmodule Gobusgo.Gbfs.VehicleStatusRetention do
  @stored_age_ms_max 10 * 60 * 1_000
  @run_interval_ms 60_000
  @run_deadline_ms 30_000
  @partition_day_count 3
  @deletion_count_max 1_000

  @moduledoc """
  Keeps every stored GBFS vehicle file for at most #{@stored_age_ms_max} ms,
  the time Lime's terms allow a raw response to be kept (GOB-253).
  `Gobusgo.Retention` counts whole days and a bucket's lifecycle rules do
  too, so this module deletes by the fetch time each destination names.

  `run/1` deletes, through `Gobusgo.Deleter`, every stored file of every
  system fetched more than `deletion_age_ms/0` before the time it is given,
  and keeps the rest. That age is #{@stored_age_ms_max} ms less one run
  interval, one run deadline, and one scheduler evaluation period, so a file
  is gone before it is #{@stored_age_ms_max} ms old although it is fetched
  just after a run, the next run starts a period late, and that run takes
  its whole deadline.

  `spec/1` is the scheduler source that runs `run/1` every
  #{@run_interval_ms} ms with a deadline of #{@run_deadline_ms} ms, whether
  or not a page shows the vehicles: the first run, at a start, removes what
  an earlier run of the application left, and later runs remove the last
  fetches once nothing is viewed. `Gobusgo.Gbfs.VehicleStatusRecorder` also
  calls `run/1` after each fetch it records.

  ## Bounds

  A run lists the partitions of the last #{@partition_day_count} UTC days of
  each system, the days that the day rule of `Gobusgo.RetentionPolicy` can
  leave in place, each through `Gobusgo.OneBusAway.StoredListing`, and
  deletes at most #{@deletion_count_max} files; what it leaves is counted as
  a backlog for the next run. A destination whose name is not one
  `Gobusgo.Gbfs.RawVehicleStatus` builds is counted and kept, and the day
  rule removes it.

  ## Results and logs

  `{:ok, counts}` when every listing and every deletion succeeded, and
  `{:error, counts}` otherwise, with `:deleted_count`, `:failed_count`,
  `:unrecognized_count`, `:listing_failed_count`, and `:backlog`, whether
  expired files are left past the bound. A run logs `Stored shared vehicles
  deleted` at `debug` when it deleted a file, `Stored shared vehicles not
  deleted` at `error` when a listing or a deletion failed, since a file can
  then outlive the terms, and nothing when nothing was expired.

  ## Options

    * `:now`: a zero-arity function returning the UTC time, by default
      `DateTime.utc_now/0`.
    * `:system_ids`: the systems whose files are deleted, by default every
      one of `Gobusgo.Gbfs.Systems.all/0`.
    * `:read_options`: options for `Gobusgo.Reader.discover/2`.
    * `:delete_options`: options for `Gobusgo.Deleter.delete/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Deleter
  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.OneBusAway.StoredListing
  alias Gobusgo.Scheduler

  @type counts :: %{
          deleted_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          unrecognized_count: non_neg_integer(),
          listing_failed_count: non_neg_integer(),
          backlog: boolean()
        }

  @doc "The longest a stored file is kept, in milliseconds."
  @spec stored_age_ms_max() :: pos_integer()
  def stored_age_ms_max, do: @stored_age_ms_max

  @doc """
  The age past which `run/1` deletes a stored file, in milliseconds: the
  longest a file is kept, less what can pass between two runs.
  """
  @spec deletion_age_ms() :: pos_integer()
  def deletion_age_ms do
    deletion_age_ms =
      @stored_age_ms_max - @run_interval_ms - @run_deadline_ms - Scheduler.evaluation_period_ms()

    Assert.condition(deletion_age_ms >= 1, "the deletion age must be positive")
    deletion_age_ms
  end

  @doc "Deletes every stored file of the systems older than `deletion_age_ms/0`."
  @spec run(Keyword.t()) :: {:ok, counts()} | {:error, counts()}
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options,
        now: &DateTime.utc_now/0,
        system_ids: nil,
        read_options: [],
        delete_options: []
      )

    now = Keyword.fetch!(options, :now).()
    Assert.condition(match?(%DateTime{time_zone: "Etc/UTC"}, now), "now must be a UTC time")
    system_ids = system_ids(Keyword.fetch!(options, :system_ids))
    Enum.each(system_ids, &Systems.assert_id/1)
    deleted_before = DateTime.add(now, -deletion_age_ms(), :millisecond)
    listing = list(%{system_ids: system_ids, now: now}, Keyword.fetch!(options, :read_options))
    {expired, unrecognized_count} = expired(listing.destinations, deleted_before)
    {deleting, left} = Enum.split(expired, @deletion_count_max)
    failed_count = delete_each(deleting, Keyword.fetch!(options, :delete_options))

    counts = %{
      deleted_count: length(deleting) - failed_count,
      failed_count: failed_count,
      unrecognized_count: unrecognized_count,
      listing_failed_count: listing.failed_count,
      backlog: left != []
    }

    log(counts)
    result(counts)
  end

  @doc """
  The spec of the scheduler that runs `run/1` every #{@run_interval_ms} ms.
  `options` are the options of `run/1`. The spec passes
  `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(Keyword.t()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: Gobusgo.Gbfs.VehicleStatusRetentionScheduler,
      run: fn -> run(options) end,
      cadence: %{policy: {:fixed, @run_interval_ms}, signals: &no_signals/0},
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  defp system_ids(nil), do: Enum.map(Systems.all(), & &1.id)
  defp system_ids(system_ids) when is_list(system_ids), do: system_ids

  defp list(%{system_ids: system_ids, now: now}, read_options) do
    today = DateTime.to_date(now)

    prefixes =
      for system_id <- system_ids, day_index <- 0..(@partition_day_count - 1)//1 do
        RawVehicleStatus.partition_prefix(system_id, Date.add(today, -day_index))
      end

    Enum.reduce(prefixes, %{destinations: [], failed_count: 0}, fn prefix, listing ->
      case StoredListing.list(prefix, read_options) do
        {:ok, destinations} -> %{listing | destinations: destinations ++ listing.destinations}
        :error -> %{listing | failed_count: listing.failed_count + 1}
      end
    end)
  end

  defp expired(destinations, deleted_before) do
    Enum.reduce(destinations, {[], 0}, fn destination, {expired, unrecognized_count} ->
      case RawVehicleStatus.parse_destination(destination) do
        {:ok, %{fetched_at: fetched_at}} ->
          if DateTime.before?(fetched_at, deleted_before) do
            {[destination | expired], unrecognized_count}
          else
            {expired, unrecognized_count}
          end

        :error ->
          {expired, unrecognized_count + 1}
      end
    end)
  end

  # A file another run deleted first is gone, which is what this run wants.
  defp delete_each(destinations, delete_options) do
    within = RawVehicleStatus.destination_prefix() <> "/"

    Enum.count(destinations, fn destination ->
      case Deleter.delete(%{destination: destination, within: within}, delete_options) do
        :ok -> false
        {:error, :not_found} -> false
        {:error, _reason} -> true
      end
    end)
  end

  defp log(%{failed_count: 0, listing_failed_count: 0, deleted_count: 0}), do: :ok

  defp log(%{failed_count: 0, listing_failed_count: 0} = counts) do
    Logger.debug("Stored shared vehicles deleted", Map.to_list(counts))
  end

  defp log(counts) do
    Logger.error("Stored shared vehicles not deleted", Map.to_list(counts))
  end

  defp result(%{failed_count: 0, listing_failed_count: 0} = counts), do: {:ok, counts}
  defp result(counts), do: {:error, counts}
end
