defmodule Gobusgo.Writer do
  @moduledoc """
  A backend-neutral contract for storing a binary under a logical destination,
  and the entry point that selects the backend.

  Callers use `write/2` and never name a backend, a filesystem path, or a
  bucket. A logical destination is a relative, `/`-separated name such as
  `"raw/oba/dt=2026-10-02/response.json"`; the backend decides where it
  physically lives.

  ## Contract

  A write is create-only: a destination that already exists yields
  `{:error, :already_exists}` and the existing content stays intact. A write
  is atomic: readers see the whole content or no object. Content is a binary,
  bounded by the backend's size limit. Missing parent levels are created.

  Results:

    * `:ok` — the content is stored at the destination.
    * `{:error, reason}` — a documented outcome, one of `t:error_reason/0`.

  Operating errors return as values. Anything outside the documented set
  (an unrecognized POSIX reason, a backend answering off-contract) raises
  `Gobusgo.AssertionError`.

  ## Selecting a backend

  Configure the default in application config:

      config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.LocalFile

  Or inject one per call with the `:backend` option. Every other option goes
  to the backend untouched.

  ## File backend example

      config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: Path.expand("data")

      :ok =
        Gobusgo.Writer.write(%{
          destination: "raw/oba/dt=2026-10-02/response.json",
          content: ~s({"ok":true})
        })

      {:error, :already_exists} =
        Gobusgo.Writer.write(%{
          destination: "raw/oba/dt=2026-10-02/response.json",
          content: "second"
        })

  ## Writing an S3 backend

  An S3 backend is a module with `@behaviour Gobusgo.Writer` and a `write/2`
  that maps the logical destination to an object key under a configured
  bucket and prefix, and returns the same results:

    * Validate the destination with `Gobusgo.Writer.Destination.resolve/2`
      semantics (the same segment rules apply to object keys).
    * Put the object with a conditional write (`If-None-Match: *`), so an
      existing key yields `{:error, :already_exists}` (HTTP 412). A put is
      atomic, so no temporary object is needed.
    * Map the provider's documented error codes to the reasons in
      `t:error_reason/0` (for example 403 to `:permission_denied`) and raise
      for undocumented ones.
    * Read the bucket and credentials from its own config key, and select it
      with `config :gobusgo, Gobusgo.Writer, backend: MyApp.S3Writer`.

  Callers do not change.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Writer.Destination

  @type request :: %{destination: String.t(), content: binary()}

  @type error_reason ::
          :already_exists
          | :permission_denied
          | :storage_full
          | :read_only
          | :io_failure
          | :destination_conflict
          | :content_too_large
          | {:invalid_destination, Destination.reason()}

  @type result :: :ok | {:error, error_reason()}

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
    Assert.that!(is_atom(backend), "backend must be a module, got: #{inspect(backend)}")

    request
    |> backend.write(backend_options)
    |> assert_result(backend)
  end

  defp configured_backend do
    :gobusgo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:backend)
  end

  defp assert_result(:ok, _backend), do: :ok

  defp assert_result({:error, reason} = result, backend) do
    Assert.that!(
      known_reason?(reason),
      "#{inspect(backend)} returned an undocumented error: #{inspect(reason)}"
    )

    result
  end

  defp assert_result(other, backend) do
    Assert.fail!("#{inspect(backend)} returned off-contract: #{inspect(other)}")
  end

  defp known_reason?(reason) do
    case reason do
      {:invalid_destination, detail} -> detail in Destination.reasons()
      atom -> atom in @error_atoms
    end
  end
end
