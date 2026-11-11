defmodule GobusgoWeb.AgencyJSON do
  @moduledoc """
  The bodies of the agency responses: `data`, the agencies as the view holds
  them, and `meta`, the fetch they come from. Everything here is pure.

  `components.schemas.AgencyCollection` and `components.schemas.AgencyResource`
  in `priv/openapi.json` describe the two bodies.
  """

  alias Gobusgo.OneBusAway.AgencyView.State

  @doc "Every agency of `fetch` in identifier order, with their count in `meta`."
  @spec index(State.current()) :: %{String.t() => term()}
  def index(%{agency_ids: agency_ids, agencies: agencies} = fetch) do
    %{
      "data" => Enum.map(agency_ids, &Map.fetch!(agencies, &1)),
      "meta" => Map.put(meta(fetch), "count", length(agency_ids))
    }
  end

  @doc "One agency of `fetch`."
  @spec show(%{agency: State.agency(), fetch: State.current()}) :: %{String.t() => term()}
  def show(%{agency: agency, fetch: fetch}) do
    %{"data" => agency, "meta" => meta(fetch)}
  end

  defp meta(%{fetched_at: fetched_at, request_id: request_id}) do
    %{"fetchedAt" => DateTime.to_iso8601(fetched_at, :extended), "requestId" => request_id}
  end
end
