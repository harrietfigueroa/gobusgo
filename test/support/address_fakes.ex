defmodule Gobusgo.Test.AddressSource do
  @moduledoc """
  A `Gobusgo.Addresses.Source` for tests of the build whose records come
  from the options of `fetch/1`: `:records`, handed over as one page,
  `:record_count`, the count the layer reports, by default that of the
  records, `:pages`, which replaces the pages, and `:answer`, which replaces
  the fetch's answer with an error.
  """

  @behaviour Gobusgo.Addresses.Source

  @impl Gobusgo.Addresses.Source
  def name, do: :test

  @impl Gobusgo.Addresses.Source
  def fetch(options) do
    case Keyword.get(options, :answer, :layer) do
      :layer ->
        records = Keyword.fetch!(options, :records)

        {:ok,
         %{
           last_edit_at: ~U[2026-11-09 12:00:00Z],
           record_count: Keyword.get(options, :record_count, length(records)),
           pages: Keyword.get(options, :pages, [{:records, records, 1}])
         }}

      other ->
        other
    end
  end
end
