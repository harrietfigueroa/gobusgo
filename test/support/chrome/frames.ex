defmodule Gobusgo.Test.Chrome.Frames do
  @moduledoc """
  The framing of the DevTools protocol over a pipe: each message is followed
  by one zero byte. Everything here is pure.
  """

  # https://chromedevtools.github.io/devtools-protocol/ ("--remote-debugging-pipe") — checked 2026-10-04
  @terminator <<0>>

  @doc "Returns `message` followed by its terminator."
  @spec frame(binary()) :: binary()
  def frame(message) when is_binary(message), do: message <> @terminator

  @doc """
  Returns the terminated messages `buffer` holds, in order, and the bytes
  after the last terminator, which are the start of a message still to come.
  """
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer) when is_binary(buffer) do
    {messages, [rest]} = buffer |> :binary.split(@terminator, [:global]) |> Enum.split(-1)
    {messages, rest}
  end
end
