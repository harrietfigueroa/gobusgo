defmodule Gobusgo.Reader.LocalFile.Listing do
  @moduledoc """
  The order and cursor rules for the entries of one directory. Pure: entries
  come in as data, which is what lets the rules be tested without a file
  system.

  Every destination below a directory starts with the directory's own
  destination followed by `/`. Sorting a directory under that key and a file
  under its destination, then expanding each directory in place, yields whole
  destinations in byte order.
  """

  alias Gobusgo.Assert

  @type entry :: %{destination: String.t(), kind: :file | :directory}
  @type bounds :: %{order: Gobusgo.Reader.order(), cursor: String.t() | nil}

  @doc """
  Returns the entries that can still yield a destination past `bounds.cursor`,
  sorted in `bounds.order`. A directory stays when the cursor lies inside it.
  """
  @spec arrange([entry()], bounds()) :: [entry()]
  def arrange(entries, %{order: order, cursor: _cursor} = bounds) when is_list(entries) do
    Assert.condition(order in [:ascending, :descending], "unknown order: #{inspect(order)}")

    entries
    |> Enum.filter(&past_cursor?(&1, bounds))
    |> Enum.sort_by(&key/1, direction(order))
  end

  defp key(%{kind: :file, destination: destination}), do: destination
  defp key(%{kind: :directory, destination: destination}), do: destination <> "/"

  defp direction(:ascending), do: :asc
  defp direction(:descending), do: :desc

  defp past_cursor?(_entry, %{cursor: nil}), do: true
  defp past_cursor?(%{kind: :file} = entry, bounds), do: past?(key(entry), bounds)

  defp past_cursor?(%{kind: :directory} = entry, bounds) do
    key = key(entry)

    if String.starts_with?(bounds.cursor, key) do
      true
    else
      past?(key, bounds)
    end
  end

  defp past?(key, %{order: :ascending, cursor: cursor}), do: key > cursor
  defp past?(key, %{order: :descending, cursor: cursor}), do: key < cursor
end
