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
  def run_deadline_ms, do: 60_000

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

defmodule Gobusgo.Test.AddressSourceTwo do
  @moduledoc """
  A second county for tests of a build over several, named `:test_two`,
  whose `fetch/1` takes the options of `Gobusgo.Test.AddressSource` and
  reports its layer as last edited a day later.
  """

  @behaviour Gobusgo.Addresses.Source

  @impl Gobusgo.Addresses.Source
  def name, do: :test_two

  @impl Gobusgo.Addresses.Source
  def run_deadline_ms, do: 60_000

  @impl Gobusgo.Addresses.Source
  def fetch(options) do
    case Gobusgo.Test.AddressSource.fetch(options) do
      {:ok, layer} -> {:ok, %{layer | last_edit_at: ~U[2026-11-10 12:00:00Z]}}
      other -> other
    end
  end
end
