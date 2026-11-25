defmodule GobusgoWeb.ServiceWorkerRelease do
  @moduledoc """
  Reads the release the service worker was built for from its release file.

  The file is read at run time on the first call for a setting, and the
  outcome is kept in `:persistent_term` until the node restarts, so a change
  to the file after that first read is not seen.

  The file's path is the one the `:service_worker_release_file` setting
  names, or the application's
  `priv/static/#{GobusgoWeb.ServiceWorker.release_file_name()}` where the
  setting names none; each setting is kept apart, so a setting pointed at
  another file reads that file.
  """

  alias GobusgoWeb.ServiceWorker

  @doc """
  Returns the release the release file names, or `:none` where the file was
  absent or named no release when the setting was first read.
  """
  @spec read() :: {:ok, String.t()} | :none
  def read do
    setting = Application.fetch_env(:gobusgo, :service_worker_release_file)
    key = {__MODULE__, setting}

    case :persistent_term.get(key, :unread) do
      :unread -> read_once(key, setting)
      kept -> kept
    end
  end

  defp read_once(key, setting) do
    release = setting |> path() |> read_file()
    :persistent_term.put(key, release)
    release
  end

  defp path({:ok, path}), do: path
  defp path(:error), do: default_path()

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
