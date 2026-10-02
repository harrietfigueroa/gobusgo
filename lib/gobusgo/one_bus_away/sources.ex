defmodule Gobusgo.OneBusAway.Sources do
  @moduledoc """
  The OneBusAway sources that run on a schedule, as specs for
  `Gobusgo.Scheduler`. Everything here is pure: it builds the specs and starts
  nothing.

  Agency discovery is the only source. It records one response through
  `Gobusgo.OneBusAway.AgencyRecorder` once a minute.
  """

  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.Scheduler

  @agency_interval_ms 60_000
  @agency_deadline_ms 45_000

  @doc """
  Returns the spec of every source. `record_options` are the options of
  `Gobusgo.OneBusAway.AgencyRecorder.record/2`.
  """
  @spec specs(Client.settings(), Keyword.t()) :: [Scheduler.spec()]
  def specs(%{base_url: base_url, api_key: api_key} = settings, record_options)
      when is_binary(base_url) and is_binary(api_key) and is_list(record_options) do
    [
      %{
        name: Gobusgo.OneBusAway.AgencyScheduler,
        # The settings travel inside the function, which prints as an opaque
        # reference, so an inspected spec never shows the key.
        run: fn -> AgencyRecorder.record(settings, record_options) end,
        interval_ms: @agency_interval_ms,
        deadline_ms: @agency_deadline_ms
      }
    ]
  end
end
