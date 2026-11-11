defmodule Gobusgo.Addresses.Source.Snohomish do
  @item_id "3c07edee19f142d2926dc1f7e4efc474"
  @layer_url "https://services6.arcgis.com/z6WYi9VRHfgwgtyW/arcgis/rest/services/Building_Address_Points/FeatureServer/0"
  @fields %{
    house_number: "Add_Number",
    house_number_suffix: "AddNum_Suf",
    pre_direction: "LSt_PreDir",
    name: "LSt_Name",
    type: "LSt_Type",
    suf_direction: "LSt_PostDir",
    city: "Post_Comm"
  }

  @moduledoc """
  Snohomish County's "Building Address Points" layer, item `#{@item_id}` of
  the county's open data portal, read in pages from its FeatureServer at
  `#{@layer_url}`, a host that publishes an IPv6 address. Read
  `lib/gobusgo/addresses/AGENTS.md` before changing it.

  A record holds the fields #{@fields |> Map.values() |> Enum.sort() |> Enum.join(", ")}
  and its point in WGS 84. The layer's `Lat` and `Long` fields are blank or
  in another projection for 27% of its rows, so the position is the
  feature's point. The street is the `LSt_*` fields, the county's short
  spelling, and the postal city is `Post_Comm`. A house number is
  `Add_Number`, and `AddNum_Suf`, when there is one, follows it after a
  space. A field the layer leaves `null` is the empty string.

  Options: `:layer_url`, and those of `Gobusgo.Addresses.ArcGis`.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.ArcGis

  @out_fields @fields |> Map.values() |> Enum.sort()

  @impl Gobusgo.Addresses.Source
  def name, do: :snohomish

  # About 1.6 times the 3,980 pages at the 3.8 requests a second King's read
  # measured on 2026-11-11.
  @impl Gobusgo.Addresses.Source
  def run_deadline_ms, do: 1_800_000

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
      house_number: house_number(attributes),
      pre_direction: text(attributes, @fields.pre_direction),
      name: text(attributes, @fields.name),
      type: text(attributes, @fields.type),
      suf_direction: text(attributes, @fields.suf_direction),
      city: text(attributes, @fields.city),
      lat: lat,
      lon: lon
    }
  end

  defp house_number(attributes) do
    number = text(attributes, @fields.house_number)

    case text(attributes, @fields.house_number_suffix) do
      "" -> number
      suffix -> number <> " " <> suffix
    end
  end

  defp text(attributes, field) do
    case Map.fetch!(attributes, field) do
      nil -> ""
      value -> value
    end
  end
end
