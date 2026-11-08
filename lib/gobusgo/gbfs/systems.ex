defmodule Gobusgo.Gbfs.Systems do
  @lime_origin "https://data.lime.bike/api/partners"
  @id_pattern ~r/\A[a-z0-9_]{1,64}\z/

  @moduledoc """
  The GBFS systems gobusgo reads, each in the form
  `Gobusgo.Gbfs.Client.fetch/3` takes with the system's identifier beside
  it. Everything here is pure.

  The one system is Lime Seattle, `lime_seattle` in the MobilityData
  catalog, read through its 3.0, 2.2, and 1.0 discovery files in English.
  Each system names the operator a page credits for its data, and the
  terms the operator publishes the feed under.

  An identifier is 1 to 64 lowercase letters, digits, and underscores, so
  it is a destination segment and a record key as it is.
  """

  alias Gobusgo.Assert

  @type system :: %{
          id: String.t(),
          operator_name: String.t(),
          terms_url: String.t(),
          terms_name: String.t(),
          discovery_urls: %{Gobusgo.Gbfs.Files.version() => String.t()},
          language: String.t()
        }

  # The discovery files of Lime Seattle, the catalog's identifier for it, and
  # the language its 1.0 and 2.2 discovery files list their feeds under.
  # https://github.com/MobilityData/gbfs/blob/master/systems.csv — checked 2026-11-08
  # The terms are the `license_url` of Lime's 3.0 `system_information`, the
  # terms the use settled in GOB-253 is read against.
  @systems [
    %{
      id: "lime_seattle",
      operator_name: "Lime",
      terms_url: "https://www.li.me/legal/public-gbfs-terms",
      terms_name: "Public GBFS Terms",
      discovery_urls: %{
        "3.0" => @lime_origin <> "/v3/gbfs/seattle/gbfs.json",
        "2.2" => @lime_origin <> "/v2/gbfs/seattle/gbfs.json",
        "1.0" => @lime_origin <> "/v1/gbfs/seattle/gbfs.json"
      },
      language: "en"
    }
  ]

  @doc "Every system, in identifier order."
  @spec all() :: [system()]
  def all do
    ids = Enum.map(@systems, & &1.id)
    Assert.condition(ids == Enum.uniq(ids), "system identifiers must be unique")
    Assert.condition(ids == Enum.sort(ids), "systems must be in identifier order")
    Enum.each(ids, &assert_id/1)
    @systems
  end

  @doc "Whether `id` has the form of a system identifier."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  @doc "Returns `:ok` for a system identifier, and raises an assertion error for any other value."
  @spec assert_id(term()) :: :ok
  def assert_id(id) do
    Assert.condition(id?(id), "a system identifier is 1 to 64 of a-z, 0-9, and _")
  end
end
