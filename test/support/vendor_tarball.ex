defmodule Gobusgo.Test.VendorTarball do
  @moduledoc """
  Builds the gzip-compressed tar archives of the vendored asset tests, in
  the forms their sources serve.
  """

  @doc "Returns the registry tarball that holds `files`, a map of path to content."
  @spec build(%{String.t() => binary()}, String.t()) :: binary()
  def build(files, tmp_dir), do: build(files, tmp_dir, "package/")

  @doc """
  Returns the archive of a repository that holds `files`, in the form GitHub
  serves: every entry under one directory named after the repository.
  """
  @spec build_repository(%{String.t() => binary()}, String.t()) :: binary()
  def build_repository(files, tmp_dir), do: build(files, tmp_dir, "repository-0123abc/")

  defp build(files, tmp_dir, prefix) when is_map(files) and is_binary(tmp_dir) do
    path = Path.join(tmp_dir, "tarball-#{System.unique_integer([:positive])}.tgz")
    entries = for {name, content} <- files, do: {String.to_charlist(prefix <> name), content}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    tarball = File.read!(path)
    File.rm!(path)
    tarball
  end
end
