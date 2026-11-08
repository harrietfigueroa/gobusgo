defmodule Gobusgo.Gbfs.Systems do
  @lime_origin "https://data.lime.bike/api/partners"

  @moduledoc """
  The GBFS systems gobusgo reads, each in the form
  `Gobusgo.Gbfs.Client.fetch/3` takes with the system's identifier beside
  it. Everything here is pure.

  The one system is Lime Seattle, `lime_seattle` in the MobilityData
  catalog, read through its 3.0, 2.2, and 1.0 discovery files in English.
  """

  alias Gobusgo.Assert

  @type system :: %{
          id: String.t(),
          discovery_urls: %{Gobusgo.Gbfs.Files.version() => String.t()},
          language: String.t()
        }

  # The discovery files of Lime Seattle, the catalog's identifier for it, and
  # the language its 1.0 and 2.2 discovery files list their feeds under.
  # https://github.com/MobilityData/gbfs/blob/master/systems.csv — checked 2026-11-08
  @systems [
    %{
      id: "lime_seattle",
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
    @systems
  end
end
