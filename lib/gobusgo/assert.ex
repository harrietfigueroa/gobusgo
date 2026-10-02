defmodule Gobusgo.AssertionError do
  @moduledoc """
  Raised when an internal invariant fails. It marks a programmer error, as
  opposed to an operating error, which is returned as a value.
  """
  defexception [:message]
end

defmodule Gobusgo.Assert do
  @moduledoc """
  Condition assertions that throw `Gobusgo.AssertionError` in every
  environment. Each carries a message naming the operand values.
  """

  @doc "Raises unless `condition` is truthy."
  @spec that!(term(), String.t()) :: :ok
  def that!(condition, message) when is_binary(message) do
    if condition do
      :ok
    else
      raise Gobusgo.AssertionError, message: message
    end
  end

  @doc "Raises unconditionally; for branches that state a violated invariant."
  @spec fail!(String.t()) :: no_return()
  def fail!(message) when is_binary(message) do
    raise Gobusgo.AssertionError, message: message
  end

  @doc "Raises for a value that no clause of an exhaustive match accounts for."
  @spec unreachable!(term()) :: no_return()
  def unreachable!(value) do
    raise Gobusgo.AssertionError, message: "unreachable value: #{inspect(value)}"
  end
end
