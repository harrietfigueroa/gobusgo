defmodule Gobusgo.Gbfs.Systems do
  @lime_seattle_id "lime_seattle"
  @system_count_max 8
  @id_pattern ~r/\A[a-z0-9_]{1,64}\z/

  @moduledoc """
  The GBFS systems gobusgo reads, in the form `Gobusgo.Gbfs.Client.fetch/3`
  takes, with the identifier each is stored and published under. Everything
  here is pure.

  The one system is Lime Seattle, `#{@lime_seattle_id}`, the identifier the
  GBFS catalog gives it, with its discovery file in 3.0, 2.2, and 1.0 (see
  `lib/gobusgo/gbfs/AGENTS.md`). An identifier is 1 to 64 lowercase letters,
  digits, and underscores, so it is a destination segment and a record key
  as it is, and there are at most #{@system_count_max} systems.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Client

  @type t :: %{
          id: String.t(),
          discovery_urls: %{Client.version() => String.t()},
          language: String.t()
        }

  @lime_origin "https://data.lime.bike/api/partners"

  @doc "Every system, at most #{@system_count_max}."
  @spec all() :: [t(), ...]
  def all do
    systems = [lime_seattle()]
    Assert.condition(length(systems) <= @system_count_max, "too many systems")
    Enum.each(systems, &assert_id(&1.id))
    systems
  end

  @doc "Lime Seattle."
  @spec lime_seattle() :: t()
  def lime_seattle do
    %{
      id: @lime_seattle_id,
      discovery_urls: %{
        "3.0" => @lime_origin <> "/v3/gbfs/seattle/gbfs.json",
        "2.2" => @lime_origin <> "/v2/gbfs/seattle/gbfs.json",
        "1.0" => @lime_origin <> "/v1/gbfs/seattle/gbfs.json"
      },
      language: "en"
    }
  end

  @doc "The most systems `all/0` holds."
  @spec system_count_max() :: pos_integer()
  def system_count_max, do: @system_count_max

  @doc "Whether `id` has the form of a system identifier."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  @doc "Returns `:ok` for a system identifier, and raises an assertion error for any other value."
  @spec assert_id(term()) :: :ok
  def assert_id(id) do
    Assert.condition(id?(id), "a system identifier is 1 to 64 of a-z, 0-9, and _")
  end
end
