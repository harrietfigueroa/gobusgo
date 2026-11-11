defmodule Gobusgo.Test.AddressSource do
  @moduledoc """
  A `Gobusgo.Addresses.Source` for tests of the build whose records come
  from the options of `fetch/2`: `:records`, written to the file as an Erlang
  term, and `:answer`, which replaces the fetch's answer with a stale export
  or an error.
  """

  @behaviour Gobusgo.Addresses.Source

  @impl Gobusgo.Addresses.Source
  def name, do: :test

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory}, options) do
    case Keyword.get(options, :answer, :export) do
      :export ->
        records = Keyword.fetch!(options, :records)
        path = Path.join(directory, "records.term")
        content = :erlang.term_to_binary(records)
        File.write!(path, content)

        {:ok,
         %{
           path: path,
           last_edit_at: Keyword.get(options, :last_edit_at, ~U[2026-11-09 12:00:00Z]),
           record_count: Keyword.get(options, :record_count, length(records)),
           byte_count: byte_size(content)
         }}

      other ->
        other
    end
  end

  @impl Gobusgo.Addresses.Source
  def records(path), do: path |> File.read!() |> :erlang.binary_to_term() |> List.wrap()
end

defmodule Gobusgo.Test.AddressSourceTwo do
  @moduledoc """
  A second `Gobusgo.Test.AddressSource` under another name, so a test of the
  build can give it two counties.
  """

  @behaviour Gobusgo.Addresses.Source

  @impl Gobusgo.Addresses.Source
  def name, do: :test_two

  @impl Gobusgo.Addresses.Source
  defdelegate fetch(request, options), to: Gobusgo.Test.AddressSource

  @impl Gobusgo.Addresses.Source
  defdelegate records(path), to: Gobusgo.Test.AddressSource
end
