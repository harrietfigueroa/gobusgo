defmodule Gobusgo.Assert do
  @moduledoc """
  Assertions for programmer errors and for payloads that violate a boundary
  contract. Every failure raises `Gobusgo.Assert.AssertionError`, so a crash
  from any helper is recognizable as a bug rather than an operating error.
  Everything here is pure.
  """

  defmodule AssertionError do
    @moduledoc "Raised by every assertion in `Gobusgo.Assert`."
    defexception [:message, :cause]

    @type t :: %__MODULE__{message: String.t(), cause: map() | nil}
  end

  alias Gobusgo.Schema

  @type schema :: Schema.t()

  @doc """
  Raises `AssertionError` with `message` unless `condition` is truthy. The
  message carries the operand values, so a failure names what broke.
  """
  @spec condition(as_boolean(term()), String.t()) :: :ok
  def condition(condition, message) when is_binary(message) do
    if condition do
      :ok
    else
      raise AssertionError, message: message
    end
  end

  @doc """
  Raises `AssertionError` for a value that no clause of an exhaustive match
  accounts for.
  """
  @spec unreachable(term()) :: no_return()
  def unreachable(value) do
    raise AssertionError, message: "unreachable value: #{inspect(value)}"
  end

  @doc """
  Returns `value` when it matches `schema`; otherwise raises `AssertionError`
  whose `cause` holds the path and the expected shape of the first mismatch.
  Map schemas require their keys and ignore unknown ones. The message and the
  cause never contain the offending value, so a payload cannot leak through a
  failed assertion.
  """
  @spec schema(term(), schema()) :: term()
  def schema(value, schema) do
    case Schema.mismatch(value, schema) do
      nil ->
        value

      %{path: path} = cause ->
        raise AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause
    end
  end
end
