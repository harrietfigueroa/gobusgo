defmodule GobusgoWeb.Mcp.OriginTest do
  # Hands the decision the Origin header values of a request and the public
  # host, and checks whether the request may proceed. The decision is pure.
  use ExUnit.Case, async: true

  alias GobusgoWeb.Mcp.Origin

  @host "gobusgo.example"

  describe "decide/2 with a public host" do
    test "allows a request with no Origin header" do
      assert Origin.decide([], @host) == :allowed
    end

    for origin <- [
          "https://gobusgo.example",
          "http://gobusgo.example",
          "https://gobusgo.example:8443",
          "https://GOBUSGO.example"
        ] do
      test "allows #{origin}, any scheme, port, and case of the public host" do
        assert Origin.decide([unquote(origin)], @host) == :allowed
      end
    end

    for origin <- [
          "https://evil.example",
          "https://gobusgo.example.evil.example",
          "https://evil-gobusgo.example",
          "https://sub.gobusgo.example"
        ] do
      test "refuses #{origin}, another host" do
        assert Origin.decide([unquote(origin)], @host) == :refused
      end
    end

    for origin <- [
          "null",
          "gobusgo.example",
          "",
          "ftp://gobusgo.example",
          "https://gobusgo.example/path",
          "https://user@gobusgo.example",
          "https://gobusgo.example?x=1"
        ] do
      test "refuses the malformed origin #{inspect(origin)}" do
        assert Origin.decide([unquote(origin)], @host) == :refused
      end
    end

    test "refuses a header sent twice, even when both name the public host" do
      assert Origin.decide(["https://gobusgo.example", "https://gobusgo.example"], @host) ==
               :refused
    end
  end

  describe "decide/2 with no public host" do
    for values <- [[], ["https://anywhere.example"], ["null"]] do
      test "allows #{inspect(values)}, as the socket accepts every origin" do
        assert Origin.decide(unquote(values), nil) == :allowed
      end
    end
  end
end
