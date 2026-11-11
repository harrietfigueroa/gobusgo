defmodule Gobusgo.Addresses.Source.King do
  @layer_url "https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @fields %{
    house_number: "ADDR_HN",
    pre_direction: "ADDR_PD",
    name: "ADDR_SN",
    type: "ADDR_ST",
    suf_direction: "ADDR_SD",
    city: "POSTALCTYNAME"
  }

  @moduledoc """
  King County's "Addresses in King County" layer, read in pages from its
  FeatureServer at `#{@layer_url}`. Read `lib/gobusgo/addresses/AGENTS.md`
  before changing it.

  A record holds the fields #{@fields |> Map.values() |> Enum.sort() |> Enum.join(", ")}
  and its point in WGS 84. A house number may hold a letter after a space
  (`"920 B"`), and a field the layer leaves empty is the empty string.

  Options: `:layer_url`, and those of `Gobusgo.Addresses.ArcGis`.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.ArcGis

  @out_fields @fields |> Map.values() |> Enum.sort()

  @impl Gobusgo.Addresses.Source
  def name, do: :king

  @impl Gobusgo.Addresses.Source
  def fetch(options) when is_list(options) do
    layer_url = Keyword.get(options, :layer_url, @layer_url)

    with {:ok, layer} <- ArcGis.layer_status(layer_url, options),
         {:ok, pages} <-
           ArcGis.pages(
             %{layer_url: layer_url, out_fields: @out_fields, record_count: layer.record_count},
             options
           ) do
      {:ok,
       %{
         last_edit_at: layer.last_edit_at,
         record_count: layer.record_count,
         pages: Stream.map(pages, &page/1)
       }}
    end
  end

  defp page({:features, features, request_count}),
    do: {:records, Enum.map(features, &record/1), request_count}

  defp page({:failed, _reason} = failure), do: failure

  defp record(%{attributes: attributes, lat: lat, lon: lon}) do
    %{
      house_number: text(attributes, @fields.house_number),
      pre_direction: text(attributes, @fields.pre_direction),
      name: text(attributes, @fields.name),
      type: text(attributes, @fields.type),
      suf_direction: text(attributes, @fields.suf_direction),
      city: text(attributes, @fields.city),
      lat: lat,
      lon: lon
    }
  end

  defp text(attributes, field) do
    case Map.fetch!(attributes, field) do
      nil -> ""
      value -> value
    end
  end
end
