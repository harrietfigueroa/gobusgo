defmodule GobusgoWeb.AgencyLive do
  @moduledoc """
  The page at `/agencies`: a test page that lists the agencies of the current
  fetch of `Gobusgo.OneBusAway.AgencyView` and names the fetch they come
  from.

  The page draws on one read of the view, so its agencies all come from one
  fetch. A connected page subscribes to the view before it reads, and reads
  again on every announcement, so it shows a fetch that completes while it
  is open. Before a fetch is complete it says that no agency data is
  available.

  An agency's website is a link only when it is an `http` or `https`
  address. Any other value is shown as text.
  """

  use Phoenix.LiveView

  alias Gobusgo.OneBusAway.AgencyView
  alias GobusgoWeb.ConnectionSignal
  alias GobusgoWeb.DonationButton

  @pubsub Gobusgo.PubSub
  @link_schemes ["http", "https"]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = AgencyView.subscribe(%{view: AgencyView, pubsub: @pubsub})
    end

    {:ok, socket |> assign(page_title: "Agencies") |> assign_fetch()}
  end

  @impl Phoenix.LiveView
  def handle_info({:agency_view_switched, AgencyView}, socket) do
    {:noreply, assign_fetch(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <ConnectionSignal.state_hook />
    <DonationButton.button class="donation-button-page" />
    <main class="mx-auto max-w-5xl p-8">
      <h1 class="text-2xl font-semibold">Agencies</h1>

      <p :if={@fetch == nil} id="no-data" class="mt-4">No agency data yet.</p>

      <div :if={@fetch != nil}>
        <p id="fetch" class="mt-2 text-sm text-slate-600">
          {length(@agencies)} agencies, fetched at {DateTime.to_iso8601(@fetch.fetched_at, :extended)} by request {@fetch.request_id}.
        </p>

        <table class="mt-4 w-full text-left text-sm">
          <thead class="border-b border-slate-300">
            <tr>
              <th class="py-2 pr-4">Identifier</th>
              <th class="py-2 pr-4">Name</th>
              <th class="py-2 pr-4">Website</th>
              <th class="py-2 pr-4">Time zone</th>
              <th class="py-2 pr-4">Coverage center (latitude, longitude)</th>
              <th class="py-2">Coverage span (latitude × longitude)</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={agency <- @agencies}
              id={"agency-#{agency["id"]}"}
              class="border-b border-slate-200"
            >
              <td class="py-2 pr-4">{agency["id"]}</td>
              <td class="py-2 pr-4">{agency["name"]}</td>
              <td class="py-2 pr-4">
                <a
                  :if={link?(agency["url"])}
                  href={agency["url"]}
                  rel="noopener noreferrer"
                  class="underline"
                >
                  {agency["url"]}
                </a>
                <span :if={not link?(agency["url"])}>{agency["url"]}</span>
              </td>
              <td class="py-2 pr-4">{agency["timezone"]}</td>
              <td class="py-2 pr-4">
                {agency["coverage"]["lat"]}, {agency["coverage"]["lon"]}
              </td>
              <td class="py-2">
                {agency["coverage"]["latSpan"]} × {agency["coverage"]["lonSpan"]}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </main>
    """
  end

  defp assign_fetch(socket) do
    case AgencyView.current(AgencyView) do
      nil ->
        assign(socket, fetch: nil, agencies: [])

      %{agency_ids: agency_ids, agencies: agencies} = fetch ->
        assign(socket, fetch: fetch, agencies: Enum.map(agency_ids, &Map.fetch!(agencies, &1)))
    end
  end

  defp link?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} -> scheme in @link_schemes
      {:error, _part} -> false
    end
  end
end
