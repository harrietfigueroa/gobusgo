defmodule Gobusgo.Retention do
  @partition_key "dt="
  @day_count_max 3_650

  @moduledoc """
  How long stored content is kept, judged from its destination alone.
  Everything here is pure, so the same rule decides for every backend.

  A rule names a dataset by the prefix of its destinations and the days its
  content is kept. A dataset stores its content by day: the segment after
  the prefix is `#{@partition_key}<date>`, a date in UTC. Content of a date
  is kept through the `day_count` days after it and is expired from the day
  after those, so it is kept at least `day_count` whole days and less than
  one day more: under a rule of one day, content of 2 October is kept on
  the 3rd and expired on the 4th.

  A destination under the prefix whose next segment is no such date is
  `:unrecognized`, and nothing here calls it expired.
  """

  alias Gobusgo.Assert

  @type rule :: %{prefix: String.t(), day_count: pos_integer()}

  @type status :: :expired | :kept | :unrecognized

  @doc """
  Returns `:ok` for a rule: a prefix with no trailing `/` and a count of
  days from 1 to #{@day_count_max}. Raises an assertion error for any other.
  """
  @spec assert_rule(rule()) :: :ok
  def assert_rule(rule) do
    Assert.condition(is_map(rule), "a rule must be a map")
    prefix = rule[:prefix]
    day_count = rule[:day_count]
    Assert.condition(is_binary(prefix), "prefix must be a string, got: #{inspect(prefix)}")
    Assert.condition(prefix != "", "prefix must be non-empty")
    Assert.condition(not String.ends_with?(prefix, "/"), "prefix must not end in /: #{prefix}")
    Assert.condition(is_integer(day_count), "day_count must be an integer")
    Assert.condition(day_count >= 1, "day_count must be positive, got: #{day_count}")
    Assert.condition(day_count <= @day_count_max, "day_count must be at most #{@day_count_max}")
  end

  @doc "The prefix every destination of the rule's dataset starts with, ending in `/`."
  @spec within(rule()) :: String.t()
  def within(%{prefix: prefix}), do: prefix <> "/"

  @doc """
  The prefix of the dataset's days: every destination that `status/1` can
  call expired or kept starts with it, and they sort by date under it.
  """
  @spec partitions_prefix(rule()) :: String.t()
  def partitions_prefix(%{prefix: prefix}), do: prefix <> "/" <> @partition_key

  @doc "Whether `destination` is expired under `rule` on the UTC date `today`."
  @spec status(%{rule: rule(), destination: String.t(), today: Date.t()}) :: status()
  def status(%{
        rule: %{day_count: day_count} = rule,
        destination: destination,
        today: %Date{} = today
      })
      when is_binary(destination) do
    case partition_date(rule, destination) do
      {:ok, date} ->
        if Date.diff(today, date) > day_count, do: :expired, else: :kept

      :error ->
        :unrecognized
    end
  end

  defp partition_date(rule, destination) do
    prefix = partitions_prefix(rule)

    with true <- String.starts_with?(destination, prefix),
         rest =
           binary_part(destination, byte_size(prefix), byte_size(destination) - byte_size(prefix)),
         [date, _content | _deeper] <- String.split(rest, "/"),
         {:ok, date} <- Date.from_iso8601(date) do
      {:ok, date}
    else
      _other -> :error
    end
  end
end
