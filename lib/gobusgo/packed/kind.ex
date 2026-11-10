defmodule Gobusgo.Packed.Kind do
  @moduledoc """
  The optional behavior of a module that knows the columns of one kind of
  packed container. A module that implements it can describe a decoded
  container in terms of its columns; `mix gobusgo.packed.decode` prints that
  description in place of the raw sections for a kind whose module is given.
  """

  @doc "Returns a JSON-encodable map describing the decoded container."
  @callback inspect(decoded :: map()) :: map()
end
