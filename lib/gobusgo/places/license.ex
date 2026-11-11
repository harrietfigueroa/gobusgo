defmodule Gobusgo.Places.License do
  @name "ODbL-1.0"
  @license_name "Open Database License 1.0"
  @uri "https://opendatacommons.org/licenses/odbl/1-0/"
  @attribution "© OpenStreetMap contributors"
  @attribution_uri "https://www.openstreetmap.org/copyright"
  @notice_destination "places/NOTICE.txt"
  @manifest_path "/places/manifest.json"

  @moduledoc """
  The license the places file is offered under, as values.

  Everything here is pure: the text of the notice stored beside the manifest
  and the `license` object of the manifest come from the same constants, so
  they cannot name different licenses.

  The places file is a Derivative Database of OpenStreetMap, offered under
  the #{@license_name} (#{@uri}), credited "#{@attribution}"
  (#{@attribution_uri}). The whole database is the file the manifest at
  `#{@manifest_path}` names, which is free to download.
  """

  @type entry :: %{String.t() => String.t()}

  @doc "The short name of the license, as the manifest states it."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The address of the license's text."
  @spec uri() :: String.t()
  def uri, do: @uri

  @doc "The credit the license requires, as text."
  @spec attribution() :: String.t()
  def attribution, do: @attribution

  @doc "The address the credit links to."
  @spec attribution_uri() :: String.t()
  def attribution_uri, do: @attribution_uri

  @doc "The address of the manifest that names the current places file."
  @spec manifest_path() :: String.t()
  def manifest_path, do: @manifest_path

  @doc "The destination the notice is stored at."
  @spec notice_destination() :: String.t()
  def notice_destination, do: @notice_destination

  @doc "The `license` object of the manifest."
  @spec manifest_entry() :: entry()
  def manifest_entry do
    %{
      "name" => @name,
      "uri" => @uri,
      "attribution" => @attribution,
      "attributionUri" => @attribution_uri,
      "notice" => @notice_destination
    }
  end

  @doc "The text of the notice stored beside the manifest."
  @spec notice_text() :: String.t()
  def notice_text do
    """
    The places file is a Derivative Database of OpenStreetMap, offered under the #{@license_name} (#{@uri}).

    #{@attribution}, #{@attribution_uri}

    The whole database is the file that the manifest at #{@manifest_path} names. It is free to download there.

    The places file is not under the license of the Gobusgo repository.
    """
  end
end
