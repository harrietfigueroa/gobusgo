defmodule Gobusgo.Test.VendorTarball do
  @moduledoc """
  Builds package tarballs for the vendored package tests, in the form the
  registry serves: a gzip-compressed tar archive with every entry under
  `package/`.
  """

  @doc "Returns the tarball that holds `files`, a map of path to content."
  @spec build(%{String.t() => binary()}, String.t()) :: binary()
  def build(files, tmp_dir) when is_map(files) and is_binary(tmp_dir) do
    path = Path.join(tmp_dir, "tarball-#{System.unique_integer([:positive])}.tgz")
    entries = for {name, content} <- files, do: {String.to_charlist("package/" <> name), content}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    tarball = File.read!(path)
    File.rm!(path)
    tarball
  end
end
