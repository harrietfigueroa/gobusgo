defmodule GobusgoWeb.ServiceWorkerRelease do
  @moduledoc """
  Reads the release the service worker was built for, from the release file
  `mix gobusgo.assets.service_worker` writes beside the worker, so the root
  layout can name the release a page belongs to.

  The file changes only with a build, so it is read on the first call for a
  path and the outcome is kept in `:persistent_term` under that path until the
  node restarts. It is read at run time, never when this module is compiled,
  since the image compiles the application before `mix assets.deploy` writes
  the file.

  The file's path is the application's
  `priv/static/#{GobusgoWeb.ServiceWorker.release_file_name()}`, or the path
  the `:service_worker_release_file` setting names; each path is kept apart,
  so a setting pointed at another file reads that file.
  """

  alias GobusgoWeb.ServiceWorker

  @doc """
  Returns the release the built worker names, or `:none` where no worker had
  been built or its release file named no release when the path was first read.
  """
  @spec read() :: {:ok, String.t()} | :none
  def read do
    path = Application.get_env(:gobusgo, :service_worker_release_file, default_path())
    key = {__MODULE__, path}

    case :persistent_term.get(key, :unread) do
      :unread -> read_once(key, path)
      kept -> kept
    end
  end

  defp read_once(key, path) do
    release = read_file(path)
    :persistent_term.put(key, release)
    release
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> release_read(content)
      {:error, _reason} -> :none
    end
  end

  defp release_read(content) do
    case ServiceWorker.release_of_file(content) do
      {:ok, release} -> {:ok, release}
      {:error, :malformed} -> :none
    end
  end

  defp default_path do
    Application.app_dir(:gobusgo, Path.join("priv/static", ServiceWorker.release_file_name()))
  end
end
