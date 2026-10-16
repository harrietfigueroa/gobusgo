defmodule Gobusgo.Config.OneBusAway do
  @moduledoc """
  The OneBusAway settings: the server's base URL and the API key. The
  inspected form leaves the key out, so a settings value that reaches a
  crash report, a log property, or `inspect/1` carries no key.
  """

  @derive {Inspect, except: [:api_key]}
  @enforce_keys [:base_url, :api_key]
  defstruct [:base_url, :api_key]

  @type t :: %__MODULE__{base_url: String.t(), api_key: String.t()}
end
