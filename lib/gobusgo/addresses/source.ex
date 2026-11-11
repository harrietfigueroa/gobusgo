defmodule Gobusgo.Addresses.Source do
  @moduledoc """
  A county's address points as the build reads them. A county is a module
  that implements this behaviour; the field mapping and the addresses of the
  county's services live in it, and nothing else in the build names a field
  or a service.

  `fetch/1` returns the county's layer: `last_edit_at`, when the county last
  edited it, `record_count`, how many records it has, which the records read
  must match, and `pages`, a lazy stream of the layer's records in pages,
  each page the records the build takes (`Gobusgo.Addresses.Accumulator`)
  with the count of requests it took. A page whose requests failed ends the
  stream as `{:failed, reason}`.
  """

  alias Gobusgo.Addresses.Accumulator

  @type page ::
          {:records, [Accumulator.county_record()], pos_integer()}
          | {:failed, term()}

  @type layer :: %{
          last_edit_at: DateTime.t(),
          record_count: non_neg_integer(),
          pages: Enumerable.t(page())
        }

  @callback name() :: atom()

  @doc """
  How long a build of the county may run, in milliseconds: its measured
  fetch time with a margin, under the scheduler's deadline.
  """
  @callback run_deadline_ms() :: pos_integer()

  @callback fetch(options :: keyword()) :: {:ok, layer()} | {:error, term()}
end
