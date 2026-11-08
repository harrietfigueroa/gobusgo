defmodule Gobusgo.OneBusAway.StoredListing do
  @page_count_max 20

  @moduledoc """
  Lists the stored responses under one prefix through
  `Gobusgo.Reader.discover/2`, page by page. A listing makes at most
  #{@page_count_max} calls of `Gobusgo.Reader.discovery_limit_max/0`
  destinations; a prefix with more is a failed listing.
  """

  alias Gobusgo.Reader

  @doc "The most discovery calls one listing makes."
  @spec page_count_max() :: pos_integer()
  def page_count_max, do: @page_count_max

  @doc """
  Returns every destination under `prefix`, or `:error` when a discovery
  fails or the prefix holds more than one listing reaches.
  """
  @spec list(String.t(), Keyword.t()) :: {:ok, [String.t()]} | :error
  def list(prefix, read_options) when is_binary(prefix) and is_list(read_options) do
    start = {:more, nil, []}

    1..@page_count_max//1
    |> Enum.reduce_while(start, fn _page, {:more, cursor, pages} ->
      request = %{
        prefix: prefix,
        limit: Reader.discovery_limit_max(),
        order: :ascending,
        cursor: cursor
      }

      case Reader.discover(request, read_options) do
        {:ok, %{destinations: destinations, cursor: nil}} ->
          {:halt, {:done, [destinations | pages]}}

        {:ok, %{destinations: destinations, cursor: next}} ->
          {:cont, {:more, next, [destinations | pages]}}

        {:error, _reason} ->
          {:halt, :error}
      end
    end)
    |> case do
      {:done, pages} -> {:ok, Enum.concat(pages)}
      {:more, _cursor, _pages} -> :error
      :error -> :error
    end
  end
end
