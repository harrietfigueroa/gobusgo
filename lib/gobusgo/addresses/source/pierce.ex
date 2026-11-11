defmodule Gobusgo.Addresses.Source.Pierce do
  @item_id "c8361c8247da4430922e4439da8513c8"
  @layer_url "https://services2.arcgis.com/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Address_Points/FeatureServer/0"
  @active_status "ACTIVE"
  @fields %{
    house_number: "HouseNumber",
    pre_direction: "PrefixDirectional",
    name: "StreetName",
    type: "StreetType",
    suf_direction: "PostDirectional",
    city: "City",
    status: "Status"
  }

  @moduledoc """
  Pierce County's "Address_Points" layer, item `#{@item_id}` of the county's
  open geospatial data portal, read in pages from its FeatureServer at
  `#{@layer_url}`, a host that publishes an IPv6 address. Read
  `lib/gobusgo/addresses/AGENTS.md` before changing it.

  A record holds the fields #{@fields |> Map.values() |> Enum.sort() |> Enum.join(", ")}
  and its point, which the layer keeps in State Plane South (EPSG 2927) and
  the query asks for in WGS 84. A field the layer leaves `null` is the empty
  string.

  A record whose `Status` is `#{@active_status}` is an address. Any other
  status, which the county gives to a temporary point on a vacant parcel, is
  read with `is_active: false`, so the accumulator counts it and leaves it
  out, and the count of records read stays the layer's.

  Options: `:layer_url`, and those of `Gobusgo.Addresses.ArcGis`.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.ArcGis

  @out_fields @fields |> Map.values() |> Enum.sort()

  @impl Gobusgo.Addresses.Source
  def name, do: :pierce

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
      lon: lon,
      is_active: text(attributes, @fields.status) == @active_status
    }
  end

  defp text(attributes, field) do
    case Map.fetch!(attributes, field) do
      nil -> ""
      value -> value
    end
  end
end
