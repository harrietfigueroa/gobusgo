defmodule Gobusgo.Reader do
  alias Gobusgo.Compression

  @discovery_limit_max 1000

  @moduledoc """
  A backend-neutral contract for discovering stored destinations and loading
  the content under a logical destination, and the entry point that selects
  the backend.

  Callers use `read/2` and `discover/2` and name no backend. A logical
  destination is a relative, `/`-separated name such as
  `"raw/oba/dt=2026-10-02/response.json"`; the backend decides where it
  physically lives.

  ## Consistency with the writer

  Destinations obey the rules in `Gobusgo.Destination`, the same rules
  `Gobusgo.Writer` enforces, so every destination a write accepts is a
  destination a read accepts, and a destination either one rejects is
  rejected by the other with the same `{:invalid_destination, reason}`.
  Content is the binary a caller passed to a write, returned unchanged. A
  write is atomic, so a read returns the whole content or
  `{:error, :not_found}`.

  ## Reading

  `read/2` returns `{:ok, content}` or `{:error, reason}`. Content is a
  binary, bounded by the backend's size limit.

  A destination that ends in `#{Compression.suffix()}` holds compressed
  content: the backend returns one gzip stream and the read returns the
  content it holds, at most #{Compression.content_bytes_max()} bytes. Every
  other destination returns what is stored.

  ## Discovery

  `discover/2` lists the destinations that hold content and start with a
  prefix, compared as strings: `"raw/oba/dt=2026-10-02/"` selects one
  partition and `"processed/20261002T000000Z-"` selects names that begin with
  a stem. The prefix rules are in `Gobusgo.Destination`; the empty prefix is
  rejected. A prefix that matches nothing yields an empty page.

  Destinations come back in byte order of the whole destination, ascending or
  descending as the request's `:order` says. One call returns at most
  `:limit` destinations, and `:limit` is at most #{@discovery_limit_max}.

  A page's `:cursor` is `nil` when the listing is complete. Otherwise pass it
  as the `:cursor` of the next request, with the same prefix and order, to
  continue after the last destination returned. The first request carries
  `cursor: nil`. Destinations stored while paging appear when they sort after
  the cursor.

  ## Outcomes

  Operating errors return as values, one of `t:error_reason/0`. Anything
  outside the documented set (a failure the backend cannot classify, a backend
  answering off-contract, a limit or order outside the contract) raises
  `Gobusgo.Assert.AssertionError`.

  ## Selecting a backend

  The application config key `:backend` under `Gobusgo.Reader` names the
  default backend module. The `:backend` option of `read/2` and `discover/2`
  overrides it per call. Every other option goes to the backend untouched.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Destination

  @type order :: :ascending | :descending

  @type discovery :: %{
          prefix: String.t(),
          limit: pos_integer(),
          order: order(),
          cursor: String.t() | nil
        }

  @type page :: %{destinations: [String.t()], cursor: String.t() | nil}

  @typedoc """
    * `:not_found` — no content is stored at the destination.
    * `:permission_denied` — the backend is not allowed to load the content
      or to list part of the prefix.
    * `:io_failure` — the storage failed while loading or listing.
    * `:content_too_large` — the content exceeds the backend's size limit,
      or compressed content expands past the limit above.
    * `:content_corrupt` — the destination holds compressed content and what
      is stored there is not one complete gzip stream.
    * `:discovery_too_large` — the backend examined more entries than its
      bound allows before filling the page; a narrower prefix avoids it.
    * `:invalid_cursor` — the cursor did not come from a page.
    * `{:invalid_destination, reason}` — the destination or the prefix breaks
      a rule; see `t:invalid_destination_reason/0`.
  """
  @type error_reason ::
          :not_found
          | :permission_denied
          | :io_failure
          | :content_too_large
          | :content_corrupt
          | :discovery_too_large
          | :invalid_cursor
          | {:invalid_destination, invalid_destination_reason()}

  @typedoc """
  Why a destination or a prefix is rejected: a logical-name rule from
  `Gobusgo.Destination`, or `:redirected` when the backend finds that it
  resolves somewhere other than its logical name.
  """
  @type invalid_destination_reason :: Destination.reason() | :redirected

  @type read_result :: {:ok, binary()} | {:error, error_reason()}
  @type discover_result :: {:ok, page()} | {:error, error_reason()}

  @invalid_destination_reasons [:redirected | Destination.reasons()]

  @error_atoms [
    :not_found,
    :permission_denied,
    :io_failure,
    :content_too_large,
    :content_corrupt,
    :discovery_too_large,
    :invalid_cursor
  ]

  @orders [:ascending, :descending]

  @doc """
  Loads the content stored at `destination`. `options` is backend-specific;
  see each backend's documentation.
  """
  @callback read(destination :: String.t(), options :: keyword()) :: read_result()

  @doc """
  Lists one page of the destinations that start with `request.prefix`, in
  `request.order`, after `request.cursor`. `options` is backend-specific.
  """
  @callback discover(discovery(), options :: keyword()) :: discover_result()

  @doc "Destinations allowed in one page."
  @spec discovery_limit_max() :: pos_integer()
  def discovery_limit_max, do: @discovery_limit_max

  @doc """
  Reads through the backend named by the `:backend` option, or by the
  application config when the option is absent.
  """
  @spec read(String.t(), keyword()) :: read_result()
  def read(destination, options \\ []) when is_binary(destination) and is_list(options) do
    {backend, backend_options} = pop_backend(options)

    case backend.read(destination, backend_options) do
      {:ok, stored} ->
        Assert.condition(is_binary(stored), "#{inspect(backend)} returned non-binary content")
        content(destination, stored)

      other ->
        assert_error(other, backend)
    end
  end

  defp content(destination, stored) do
    if Compression.compressed?(destination) do
      case Compression.decompress(stored, Compression.content_bytes_max()) do
        {:ok, content} -> {:ok, content}
        {:error, :corrupt} -> {:error, :content_corrupt}
        {:error, :too_large} -> {:error, :content_too_large}
      end
    else
      {:ok, stored}
    end
  end

  @doc """
  Discovers through the backend named by the `:backend` option, or by the
  application config when the option is absent. Every key of the request is
  required.
  """
  @spec discover(discovery(), keyword()) :: discover_result()
  def discover(
        %{prefix: prefix, limit: limit, order: order, cursor: cursor} = request,
        options \\ []
      )
      when is_binary(prefix) and (is_binary(cursor) or is_nil(cursor)) and is_list(options) do
    Assert.condition(is_integer(limit), "limit must be an integer, got: #{inspect(limit)}")
    Assert.condition(limit >= 1, "limit must be at least 1, got: #{limit}")

    Assert.condition(
      limit <= @discovery_limit_max,
      "limit must be at most #{@discovery_limit_max}, got: #{limit}"
    )

    Assert.condition(order in @orders, "order must be one of #{inspect(@orders)}")
    {backend, backend_options} = pop_backend(options)

    case backend.discover(request, backend_options) do
      {:ok, page} = result ->
        assert_page(%{page: page, request: request, backend: backend})
        result

      other ->
        assert_error(other, backend)
    end
  end

  defp pop_backend(options) do
    {backend, backend_options} = Keyword.pop_lazy(options, :backend, &configured_backend/0)
    Assert.condition(is_atom(backend), "backend must be a module, got: #{inspect(backend)}")
    {backend, backend_options}
  end

  defp configured_backend do
    :gobusgo
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:backend)
  end

  defp assert_page(%{page: page, request: request, backend: backend}) do
    Assert.condition(
      match?(%{destinations: destinations, cursor: _cursor} when is_list(destinations), page),
      "#{inspect(backend)} returned an off-contract page"
    )

    %{destinations: destinations, cursor: cursor} = page
    count = length(destinations)

    Assert.condition(
      count <= request.limit,
      "#{inspect(backend)} returned #{count} destinations for limit #{request.limit}"
    )

    Assert.condition(
      Enum.all?(destinations, &(is_binary(&1) and String.starts_with?(&1, request.prefix))),
      "#{inspect(backend)} returned a destination outside the prefix"
    )

    Assert.condition(
      is_nil(cursor) or is_binary(cursor),
      "#{inspect(backend)} returned an off-contract cursor"
    )

    if is_binary(cursor) do
      Assert.condition(count >= 1, "#{inspect(backend)} returned a cursor on an empty page")
    end

    :ok
  end

  defp assert_error({:error, reason} = result, backend) do
    Assert.condition(
      known_reason?(reason),
      "#{inspect(backend)} returned an undocumented error: #{inspect(reason)}"
    )

    result
  end

  defp assert_error(_other, backend) do
    raise Assert.AssertionError, message: "#{inspect(backend)} returned off-contract"
  end

  defp known_reason?(reason) do
    case reason do
      {:invalid_destination, detail} -> detail in @invalid_destination_reasons
      atom -> atom in @error_atoms
    end
  end
end
