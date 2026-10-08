defmodule Gobusgo.Usage.UserAgentTest do
  # Verifies the classification as a pure function of a user agent, over
  # user agents of the browsers and devices the rules name, and over input
  # that is no user agent at all.
  use ExUnit.Case, async: true

  alias Gobusgo.Usage.UserAgent

  @iphone_safari "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
  @iphone_chrome "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.0.0 Mobile/15E148 Safari/604.1"
  @android_chrome "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36"
  @android_tablet "Mozilla/5.0 (Linux; Android 15; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  @android_samsung "Mozilla/5.0 (Linux; Android 15; SM-S921U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36"
  @android_firefox "Mozilla/5.0 (Android 15; Mobile; rv:143.0) Gecko/143.0 Firefox/143.0"
  @ipad_safari "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  @mac_safari "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  @mac_chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  @windows_edge "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0"
  @windows_opera "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36 OPR/123.0.0.0"
  @linux_firefox "Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0"
  @googlebot "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @headless_chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/141.0.0.0 Safari/537.36"

  describe "classify/1" do
    for {label, user_agent, device_class, browser_family} <- [
          {"Safari on an iPhone", @iphone_safari, "mobile", "safari"},
          {"Chrome on an iPhone", @iphone_chrome, "mobile", "chrome"},
          {"Chrome on an Android phone", @android_chrome, "mobile", "chrome"},
          {"Chrome on an Android tablet", @android_tablet, "tablet", "chrome"},
          {"Samsung Internet on a phone", @android_samsung, "mobile", "samsung"},
          {"Firefox on an Android phone", @android_firefox, "mobile", "firefox"},
          {"Safari on an iPad", @ipad_safari, "tablet", "safari"},
          {"Safari on a Mac", @mac_safari, "desktop", "safari"},
          {"Chrome on a Mac", @mac_chrome, "desktop", "chrome"},
          {"Edge on Windows", @windows_edge, "desktop", "edge"},
          {"Opera on Windows", @windows_opera, "desktop", "opera"},
          {"Firefox on Linux", @linux_firefox, "desktop", "firefox"},
          {"a crawler that names a phone", @googlebot, "bot", "chrome"},
          {"a headless Chrome", @headless_chrome, "bot", "chrome"},
          {"a client that is no browser", "curl/8.7.1", "unknown", "other"},
          {"no user agent", nil, "unknown", "unknown"},
          {"an empty user agent", "", "unknown", "unknown"},
          {"a blank user agent", "   ", "unknown", "unknown"},
          {"bytes that are no text", <<255, 254, 253>>, "unknown", "unknown"}
        ] do
      test "calls #{label} a #{device_class} with the browser #{browser_family}" do
        assert UserAgent.classify(unquote(user_agent)) == %{
                 device_class: unquote(device_class),
                 browser_family: unquote(browser_family)
               }
      end
    end

    test "reads only the start of a long user agent" do
      long = String.duplicate("x", 600) <> " iPhone Safari/604.1"

      assert UserAgent.classify(long) == %{device_class: "unknown", browser_family: "other"}
    end

    test "returns only classes and families the module lists" do
      for user_agent <- [@iphone_safari, @googlebot, "curl/8.7.1", nil] do
        %{device_class: device_class, browser_family: browser_family} =
          UserAgent.classify(user_agent)

        assert device_class in UserAgent.device_classes()
        assert browser_family in UserAgent.browser_families()
      end
    end
  end
end
