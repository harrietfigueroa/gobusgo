defmodule Gobusgo.Addresses.Shards do
  @prefix_length_max 32
  @own_name_mark "$"

  @moduledoc """
  Cuts the streets of an index into shards by the prefix of their name key,
  the street's normalized name with its spaces removed, so a search reads
  the one shard its street's name selects.

  A shard is the longest prefix, starting from the empty one, whose streets
  encode to at most `bytes_max` bytes. A group that is over the bound splits
  by the next letter of its name keys; the streets whose name key is the
  prefix itself stay in a shard of their own, named by the prefix and
  `#{inspect(@own_name_mark)}`, since no letter follows to place them. A group
  whose name keys all continue with one letter descends to that letter
  without a shard of its own. A group at #{@prefix_length_max} letters, the
  longest prefix a search tries, or a group of one name key that is over the
  bound is a shard as large as it is.

  The size is measured on the encoded bytes before they are compressed:
  `encode` is the function that turns a group of streets into the content of
  a shard, and each shard carries the content it was measured with. A group
  whose `bytes_min`, a lower bound on its encoded size, is already over the
  bound is split without being encoded, which keeps the encoding of the
  county's whole street list off the heap.
  Everything here is
  pure; the work is bounded by one encoding of each group at each of the at
  most #{@prefix_length_max} levels.
  """

  alias Gobusgo.Addresses.Accumulator
  alias Gobusgo.Assert

  @type shard :: %{
          prefix: String.t(),
          streets: [Accumulator.street()],
          content: binary()
        }

  @doc "The longest prefix a shard is named by."
  @spec prefix_length_max() :: pos_integer()
  def prefix_length_max, do: @prefix_length_max

  @doc "The mark that ends the prefix of a shard that holds the streets named by the prefix alone."
  @spec own_name_mark() :: String.t()
  def own_name_mark, do: @own_name_mark

  @doc """
  The shards of `streets`, which must be in the order of their name keys, in
  the order of their prefixes. Every street is in exactly one shard.
  """
  @spec split([Accumulator.street()], %{
          encode: ([Accumulator.street()] -> binary()),
          bytes_min: ([Accumulator.street()] -> non_neg_integer()),
          bytes_max: pos_integer()
        }) :: [shard()]
  def split(streets, %{encode: encode, bytes_min: bytes_min, bytes_max: bytes_max})
      when is_list(streets) and is_function(encode, 1) and is_function(bytes_min, 1) and
             is_integer(bytes_max) and bytes_max > 0 do
    shards =
      shards(%{
        pending: [{"", streets}],
        done: [],
        encode: encode,
        bytes_min: bytes_min,
        bytes_max: bytes_max
      })

    Assert.condition(
      Enum.sum(for shard <- shards, do: length(shard.streets)) == length(streets),
      "every street is in a shard"
    )

    Enum.sort_by(shards, & &1.prefix)
  end

  defp shards(%{pending: []} = state), do: state.done

  defp shards(%{pending: [{prefix, group} | pending]} = state) do
    state = %{state | pending: pending}

    if group == [] do
      shards(state)
    else
      shards(step(prefix, group, state))
    end
  end

  defp step(prefix, group, state) do
    prefix_length = String.length(prefix)
    is_longest = prefix_length >= @prefix_length_max
    is_certainly_large = state.bytes_min.(group) > state.bytes_max
    is_split_without_encoding = is_certainly_large and prefix_length < @prefix_length_max

    if is_split_without_encoding do
      split_group(%{prefix: prefix, group: group}, state)
    else
      content = state.encode.(group)
      is_small = byte_size(content) <= state.bytes_max

      if is_small or is_longest do
        done(state, %{prefix: prefix, streets: group, content: content})
      else
        split_group(%{prefix: prefix, group: group}, state)
      end
    end
  end

  defp split_group(%{prefix: prefix, group: group}, state) do
    prefix_length = String.length(prefix)
    {own, longer} = Enum.split_with(group, &(String.length(&1.name_key) <= prefix_length))
    children = Enum.group_by(longer, &String.slice(&1.name_key, 0, prefix_length + 1))
    is_splittable = own != [] or map_size(children) > 1
    is_one_name = group |> Enum.map(& &1.name_key) |> Enum.uniq() |> length() == 1

    cond do
      is_one_name ->
        done(state, %{prefix: prefix, streets: group, content: state.encode.(group)})

      is_splittable ->
        state = own_shard(state, prefix, own)
        %{state | pending: Enum.sort(children) ++ state.pending}

      true ->
        [{child, streets}] = Map.to_list(children)
        %{state | pending: [{child, streets} | state.pending]}
    end
  end

  defp own_shard(state, _prefix, []), do: state

  defp own_shard(state, prefix, own) do
    done(state, %{
      prefix: prefix <> @own_name_mark,
      streets: own,
      content: state.encode.(own)
    })
  end

  defp done(state, shard), do: %{state | done: [shard | state.done]}
end
