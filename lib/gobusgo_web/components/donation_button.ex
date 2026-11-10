defmodule GobusgoWeb.DonationButton do
  @moduledoc """
  The donation button of a browser page: a link to the donation address of
  `Gobusgo.Config.donation_url/0`, drawn as a cup with a heart in the
  surface style, which opens the address in a new tab. With no address
  configured it renders nothing.

  The button is a plain link with an inline symbol, so a page requests
  nothing from the donation site until the rider follows it.
  """

  use Phoenix.Component

  alias GobusgoWeb.AppInfo

  @doc """
  The button. `class` names where the page places it, such as
  `donation-button-map` over a map's top left corner.
  """
  attr :class, :string, default: nil

  def button(assigns) do
    {:ok, url} = Gobusgo.Config.donation_url()
    assigns = assign(assigns, url: url, label: AppInfo.donation_label())

    ~H"""
    <a
      :if={@url}
      id="donation-button"
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={@label}
      title={@label}
      class={["donation-button surface", @class]}
    >
      <.symbol />
    </a>
    """
  end

  @doc """
  The donation section of the info panel's About group: a headline and a
  caption of what donations fund, from `GobusgoWeb.AppInfo`, the same link
  as the button, and the full statement behind a disclosure. With no
  address configured it renders nothing.
  """
  def section(assigns) do
    {:ok, url} = Gobusgo.Config.donation_url()

    assigns =
      assign(assigns,
        url: url,
        label: AppInfo.donation_label(),
        summary: AppInfo.summary(:donation),
        text: AppInfo.donation()
      )

    ~H"""
    <section :if={@url} id="app-info-donation" class="flex flex-col gap-2">
      <h3 class="message-headline">{@summary.headline}</h3>
      <p class="message-caption">{@summary.caption}</p>
      <p>
        <a
          id="app-info-donation-link"
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-2 font-semibold underline"
        >
          <.symbol />{@label}
        </a>
      </p>
      <details id="app-info-donation-more" class="app-info-more">
        <summary class="inline-target cursor-pointer">What donations fund</summary>
        <p class="pt-2">{@text}</p>
      </details>
    </section>
    """
  end

  defp symbol(assigns) do
    ~H"""
    <svg aria-hidden="true" class="donation-symbol" viewBox="0 0 24 24">
      <path d="M4 9 H16 V14 A5 5 0 0 1 11 19 H9 A5 5 0 0 1 4 14 Z" />
      <path d="M16 10.5 H17.5 A2.5 2.5 0 0 1 17.5 15.5 H15.4" />
      <path d="M8 3.5 V6 M12 3.5 V6" />
      <path
        class="donation-symbol-heart"
        d="M10 16.2 L7.9 14.1 A1.5 1.5 0 0 1 10 12 A1.5 1.5 0 0 1 12.1 14.1 Z"
      />
    </svg>
    """
  end
end
