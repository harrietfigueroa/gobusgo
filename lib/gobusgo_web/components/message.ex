defmodule GobusgoWeb.Message do
  @moduledoc """
  A status message as two lines: a bold headline that states the state,
  and a muted caption with the next step or the detail. The headline ends
  in a visually hidden full stop, so an element that reads the two reads
  two sentences.
  """

  use Phoenix.Component

  @doc "The headline and the caption, for an element that holds them."
  attr :headline, :string, required: true
  attr :caption, :string, required: true

  def message(assigns) do
    ~H"""
    <span class="message-headline">{@headline}<span class="sr-only">. </span></span><span class="message-caption">{@caption}</span>
    """
  end
end
