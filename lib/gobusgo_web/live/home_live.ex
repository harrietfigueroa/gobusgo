defmodule GobusgoWeb.HomeLive do
  @moduledoc """
  The page at `/`: a placeholder that shows the front end is served and its
  LiveView connects.
  """

  use Phoenix.LiveView

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-2xl p-8">
      <h1 class="text-2xl font-semibold">Gobusgo</h1>
      <p class="mt-2">The front end is running.</p>
    </main>
    """
  end
end
