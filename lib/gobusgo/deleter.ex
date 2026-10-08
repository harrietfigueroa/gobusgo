defmodule Gobusgo.Deleter do
  @moduledoc """
  A backend-neutral contract for removing the content stored under a logical
  destination, and the entry point that selects the backend.

  Callers use `delete/2` and name no backend. A logical destination is a
  relative, `/`-separated name whose rules are in `Gobusgo.Destination`, the
  same rules `Gobusgo.Writer` and `Gobusgo.Reader` enforce.

  ## Contract

  After `:ok` the destination holds no content: a read of it returns
  `{:error, :not_found}` and discovery leaves it out. A destination that
  holds no content yields `{:error, :not_found}`, so deleting twice is an
  outcome and no failure. A delete is atomic: a reader sees the whole content
  or none.

  A request names `within`, a prefix of the destination that ends in `/`.
  Whatever hierarchy below `within` the deletion leaves empty goes with the
  content, and nothing at `within` or above it does: with
  `within: "raw/oba/"`, deleting the last content under
  `raw/oba/dt=2026-10-02/` leaves `raw/oba/` in place for the next write.

  Results:

    * `:ok` — the destination holds no content.
    * `{:error, reason}` — a documented outcome, one of `t:error_reason/0`.

  Operating errors return as values. Anything outside the documented set (a
  failure the backend cannot classify, a backend answering off-contract, a
  `within` that is no such prefix) raises `Gobusgo.Assert.AssertionError`.

  ## Selecting a backend

  The application config key `:backend` under `Gobusgo.Deleter` names the
  default backend module. The `:backend` option of `delete/2` overrides it
  per call. Every other option goes to the backend untouched.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Destination

  @type request :: %{destination: String.t(), within: String.t()}

  @typedoc """
    * `:not_found` — no content is stored at the destination.
    * `:permission_denied` — the backend is not allowed to remove it.
    * `:read_only` — the storage accepts no change.
    * `:io_failure` — the storage failed while removing.
    * `:destination_conflict` — the destination names a level of the
      hierarchy and no content.
    * `{:invalid_destination, reason}` — the destination breaks a rule; see
      `t:invalid_destination_reason/0`.
  """
  @type error_reason ::
          :not_found
          | :permission_denied
          | :read_only
          | :io_failure
          | :destination_conflict
          | {:invalid_destination, invalid_destination_reason()}

  @typedoc """
  Why a destination is rejected: a logical-name rule from `Gobusgo.Destination`,
  or `:redirected` when the backend finds that the destination resolves somewhere
  other than its logical name.
  """
  @type invalid_destination_reason :: Destination.reason() | :redirected

  @type result :: :ok | {:error, error_reason()}

  @invalid_destination_reasons [:redirected | Destination.reasons()]

  @error_atoms [:not_found, :permission_denied, :read_only, :io_failure, :destination_conflict]

  @doc """
  Removes the content at `request.destination`, with whatever hierarchy
  below `request.within` that leaves empty. `options` is backend-specific;
  see each backend's documentation.
  """
  @callback delete(request(), options :: keyword()) :: result()

  @doc """
  Deletes through the backend named by the `:backend` option, or by the
  application config when the option is absent.
  """
  @spec delete(request(), keyword()) :: result()
  def delete(%{destination: destination, within: within} = request, options \\ [])
      when is_binary(destination) and is_binary(within) and is_list(options) do
    Assert.condition(String.ends_with?(within, "/"), "within must end in /, got: #{within}")

    Assert.condition(
      String.starts_with?(destination, within),
      "within must be a prefix of the destination, got: #{within}"
    )

    Assert.condition(
      byte_size(destination) > byte_size(within),
      "the destination must name content below within, got: #{destination}"
    )

    {backend, backend_options} = Keyword.pop_lazy(options, :backend, &configured_backend/0)
    Assert.condition(is_atom(backend), "backend must be a module, got: #{inspect(backend)}")

    request
    |> backend.delete(backend_options)
    |> assert_result(backend)
  end

  defp configured_backend do
    :gobusgo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:backend)
  end

  defp assert_result(:ok, _backend), do: :ok

  defp assert_result({:error, reason} = result, backend) do
    Assert.condition(
      known_reason?(reason),
      "#{inspect(backend)} returned an undocumented error: #{inspect(reason)}"
    )

    result
  end

  defp assert_result(other, backend) do
    raise Assert.AssertionError,
      message: "#{inspect(backend)} returned off-contract: #{inspect(other)}"
  end

  defp known_reason?(reason) do
    case reason do
      {:invalid_destination, detail} -> detail in @invalid_destination_reasons
      atom -> atom in @error_atoms
    end
  end
end
