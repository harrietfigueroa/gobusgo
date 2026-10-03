defmodule Gobusgo.Writer do
  alias Gobusgo.Compression

  @moduledoc """
  A backend-neutral contract for storing a binary under a logical destination,
  and the entry point that selects the backend.

  Callers use `write/2` and name no backend. A logical destination is a
  relative, `/`-separated name such as `"raw/oba/dt=2026-10-02/response.json"`
  whose rules are in `Gobusgo.Destination`; the backend decides where
  it physically lives.

  ## Contract

  A write is create-only: a destination that already exists yields
  `{:error, :already_exists}` and the existing content stays intact. A write
  is atomic: readers see the whole content or nothing. Content is a binary,
  bounded by the backend's size limit. Any hierarchy the destination implies
  is created.

  A destination that ends in `#{Compression.suffix()}` holds compressed
  content: the caller passes the content as it is, at most
  #{Compression.content_bytes_max()} bytes, and the backend stores it as one
  gzip stream. Every other destination stores the content unchanged.

  Results:

    * `:ok` — the content is stored at the destination.
    * `{:error, reason}` — a documented outcome, one of `t:error_reason/0`.

  Operating errors return as values. Anything outside the documented set
  (a failure the backend cannot classify, a backend answering off-contract)
  raises `Gobusgo.Assert.AssertionError`.

  ## Selecting a backend

  The application config key `:backend` under `Gobusgo.Writer` names the
  default backend module. The `:backend` option of `write/2` overrides it per
  call. Every other option goes to the backend untouched.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Destination

  @type request :: %{destination: String.t(), content: binary()}

  @type error_reason ::
          :already_exists
          | :permission_denied
          | :storage_full
          | :read_only
          | :io_failure
          | :destination_conflict
          | :content_too_large
          | {:invalid_destination, invalid_destination_reason()}

  @typedoc """
  Why a destination is rejected: a logical-name rule from `Gobusgo.Destination`,
  or `:redirected` when the backend finds that the destination resolves somewhere
  other than its logical name.
  """
  @type invalid_destination_reason :: Destination.reason() | :redirected

  @type result :: :ok | {:error, error_reason()}

  @invalid_destination_reasons [:redirected | Destination.reasons()]

  @error_atoms [
    :already_exists,
    :permission_denied,
    :storage_full,
    :read_only,
    :io_failure,
    :destination_conflict,
    :content_too_large
  ]

  @doc """
  Stores `request.content` at `request.destination`, create-only. `options`
  is backend-specific; see each backend's documentation.
  """
  @callback write(request(), options :: keyword()) :: result()

  @doc """
  Writes through the backend named by the `:backend` option, or by the
  application config when the option is absent.
  """
  @spec write(request(), keyword()) :: result()
  def write(%{destination: destination, content: content} = request, options \\ [])
      when is_binary(destination) and is_binary(content) and is_list(options) do
    {backend, backend_options} = Keyword.pop_lazy(options, :backend, &configured_backend/0)
    Assert.condition(is_atom(backend), "backend must be a module, got: #{inspect(backend)}")

    case stored_content(destination, content) do
      {:ok, stored} ->
        %{request | content: stored}
        |> backend.write(backend_options)
        |> assert_result(backend)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stored_content(destination, content) do
    if Compression.compressed?(destination) do
      if byte_size(content) <= Compression.content_bytes_max() do
        {:ok, Compression.compress(content)}
      else
        {:error, :content_too_large}
      end
    else
      {:ok, content}
    end
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
