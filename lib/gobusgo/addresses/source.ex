defmodule Gobusgo.Addresses.Source do
  @moduledoc """
  A county's address points as the build reads them: how to fetch the
  county's whole layer into a file, and how to read the file's rows as the
  records `Gobusgo.Addresses.Accumulator` takes. A county is a module that
  implements this behaviour; the field mapping and the addresses of the
  county's services live in it, and nothing else in the build names a field
  or a service.

  `fetch/2` writes the layer to a file in `request.directory`, at most
  `request.bytes_max` bytes of it, and returns what it holds:
  `last_edit_at`, when the county last edited the layer, and `record_count`,
  how many records the layer has, which a file read to its end must match.
  An export that is older than the layer it exports is not an error but a
  known outcome, `{:stale, details}`, which the build logs and answers by
  keeping the files it has.

  `records/1` returns a lazy stream over the rows of the file `fetch/2`
  wrote, one record per row.
  """

  alias Gobusgo.Addresses.Accumulator

  @type export :: %{
          path: String.t(),
          last_edit_at: DateTime.t(),
          record_count: non_neg_integer(),
          byte_count: non_neg_integer()
        }

  @type stale :: %{
          reason: :export_older_than_layer | :record_count_differs | :export_metadata_missing,
          layer_last_edit_at: DateTime.t(),
          layer_record_count: non_neg_integer()
        }

  @callback name() :: atom()

  @callback fetch(
              request :: %{directory: String.t(), bytes_max: pos_integer()},
              options :: keyword()
            ) :: {:ok, export()} | {:stale, stale()} | {:error, term()}

  @callback records(path :: String.t()) :: Enumerable.t(Accumulator.county_record())
end
