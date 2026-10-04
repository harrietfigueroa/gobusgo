defmodule Gobusgo.VendorAssets.Github do
  @archive_bytes_max 67_108_864

  @moduledoc """
  The GitHub request of the vendored archives: the archive of a repository
  at a commit. Read `AGENTS.md` beside this module before changing it.

  The request goes through `Gobusgo.VendorAssets.Http`, carries no
  credential, and refuses an archive of more than #{@archive_bytes_max}
  bytes.

  Errors:

    * `:not_found`: GitHub has no such repository or commit
    * `{:http_status, status}`: any other status that is not 200
    * a `Gobusgo.VendorAssets.Http` error

  Options are those of `Gobusgo.VendorAssets.Http.get/2`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.VendorAssets.Http
  alias Gobusgo.VendorAssets.Lock

  @archive_url "https://codeload.github.com"
  @user_agent "gobusgo-vendor-assets"

  @type error :: :not_found | {:http_status, pos_integer()} | Http.error()

  @doc """
  Returns the gzip-compressed tar archive of `request.repository`,
  `owner/name`, at `request.commit`.
  """
  @spec fetch_archive(%{repository: String.t(), commit: String.t()}, keyword()) ::
          {:ok, binary()} | {:error, error()}
  def fetch_archive(%{repository: repository, commit: commit}, options) when is_list(options) do
    Assert.condition(Lock.valid_repository?(repository), "repository must be owner/name")
    Assert.condition(Lock.valid_commit?(commit), "commit must be 40 hexadecimal digits")

    request = %{
      url: "#{@archive_url}/#{repository}/tar.gz/#{commit}",
      headers: [{"accept", "application/x-gzip"}, {"user-agent", @user_agent}],
      bytes_max: @archive_bytes_max
    }

    case Http.get(request, options) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      # The archive host is where GitHub's documented archive endpoint
      # redirects, and its own statuses are undocumented; observed on
      # 2026-10-04: 404 for a commit the repository does not have.
      # https://docs.github.com/en/rest/repos/contents?apiVersion=2022-11-28#download-a-repository-archive-tar — checked 2026-10-04
      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
