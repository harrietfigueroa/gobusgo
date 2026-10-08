defmodule Gobusgo.Usage.UserAgent do
  @user_agent_bytes_max 512

  @moduledoc """
  The class of device and the family of browser a user agent names, the two
  facts a usage record keeps of it. Everything here is pure, and the user
  agent itself is returned nowhere.

  The rules read the first #{@user_agent_bytes_max} bytes, in this order:

    * A device is `bot` when the user agent names a crawler or a headless
      browser, then `tablet` for an iPad, a tablet, or an Android device
      that does not call itself mobile, then `mobile` for a phone, then
      `desktop` for Windows, macOS, Linux, or ChromeOS, and `unknown`
      otherwise.
    * A browser is the first of `edge`, `opera`, `samsung`, `firefox`,
      `chrome`, and `safari` that the user agent names, because Edge, Opera,
      and Samsung Internet also name Chrome, and Chrome also names Safari.
      Any other is `other`.

  An iPad that asks for desktop sites sends the user agent of a Mac, so it
  is a `desktop`. A missing or empty user agent is `unknown` in both.
  """

  @type device_class :: String.t()
  @type browser_family :: String.t()
  @type t :: %{device_class: device_class(), browser_family: browser_family()}

  @device_classes ["mobile", "tablet", "desktop", "bot", "unknown"]
  @browser_families [
    "edge",
    "opera",
    "samsung",
    "firefox",
    "chrome",
    "safari",
    "other",
    "unknown"
  ]

  @bot_pattern ~r/bot|crawl|spider|headless/i
  @tablet_pattern ~r/iPad|Tablet/
  @mobile_pattern ~r/Mobi|iPhone|iPod/
  @android_pattern ~r/Android/
  @desktop_pattern ~r/Windows|Macintosh|X11|Linux|CrOS/

  @browser_patterns [
    {"edge", ~r/Edg(e|A|iOS)?\//},
    {"opera", ~r/OPR\/|Opera/},
    {"samsung", ~r/SamsungBrowser\//},
    {"firefox", ~r/Firefox\/|FxiOS\//},
    {"chrome", ~r/Chrome\/|CriOS\/|Chromium\//},
    {"safari", ~r/Safari\//}
  ]

  @doc "Every device class `classify/1` returns."
  @spec device_classes() :: [device_class(), ...]
  def device_classes, do: @device_classes

  @doc "Every browser family `classify/1` returns."
  @spec browser_families() :: [browser_family(), ...]
  def browser_families, do: @browser_families

  @doc "The device class and the browser family of `user_agent`, `nil` for none sent."
  @spec classify(String.t() | nil) :: t()
  def classify(nil), do: %{device_class: "unknown", browser_family: "unknown"}

  def classify(user_agent) when is_binary(user_agent) do
    read = binary_part(user_agent, 0, min(byte_size(user_agent), @user_agent_bytes_max))

    case String.valid?(read) and String.trim(read) != "" do
      true -> %{device_class: device_class(read), browser_family: browser_family(read)}
      false -> classify(nil)
    end
  end

  defp device_class(user_agent) do
    cond do
      user_agent =~ @bot_pattern -> "bot"
      user_agent =~ @tablet_pattern -> "tablet"
      user_agent =~ @mobile_pattern -> "mobile"
      user_agent =~ @android_pattern -> "tablet"
      user_agent =~ @desktop_pattern -> "desktop"
      true -> "unknown"
    end
  end

  defp browser_family(user_agent) do
    Enum.find_value(@browser_patterns, "other", fn {family, pattern} ->
      if user_agent =~ pattern, do: family
    end)
  end
end
