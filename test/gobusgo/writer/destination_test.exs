defmodule Gobusgo.Writer.DestinationTest do
  # Verifies logical destination validation as a pure function of the
  # destination string and an absolute base directory.
  use ExUnit.Case, async: true

  alias Gobusgo.Writer.Destination

  @base "/var/data"

  describe "resolve/2 accepts" do
    test "a single segment" do
      assert Destination.resolve("a.json", @base) ==
               {:ok, %{segments: ["a.json"], path: "/var/data/a.json"}}
    end

    test "the partitioned layout with equals signs, underscores, and colons-free timestamps" do
      destination =
        "raw/oba/agencies-with-coverage/dt=2026-10-02/20261002T031500Z_0199c4a2_3f9a1c07be52.json"

      assert {:ok, %{segments: segments, path: path}} = Destination.resolve(destination, @base)
      assert length(segments) == 5
      assert path == Path.join(@base, destination)
    end
  end

  describe "resolve/2 rejects" do
    for {name, destination, reason} <- [
          {"an empty string", "", :empty},
          {"an absolute path", "/etc/passwd", :absolute},
          {"a dot-dot segment", "a/../b", :segment_invalid},
          {"a leading dot-dot", "../escape", :segment_invalid},
          {"a lone dot segment", "a/./b", :segment_invalid},
          {"a hidden file", ".hidden", :segment_invalid},
          {"an empty segment", "a//b", :segment_invalid},
          {"a trailing slash", "a/", :segment_invalid},
          {"a space", "a b", :segment_invalid},
          {"a backslash", "a\\b", :segment_invalid},
          {"a colon", "a:b", :segment_invalid},
          {"a trailing newline", "a\n", :segment_invalid},
          {"a NUL byte", "a\0b", :nul_byte},
          {"invalid UTF-8", <<"a", 255>>, :not_utf8},
          {"a non-ASCII letter", "café", :segment_invalid},
          {"an overlong segment", String.duplicate("a", 129), :segment_too_long},
          {"too many segments", Enum.join(List.duplicate("a", 17), "/"), :too_deep},
          {"an overlong destination",
           Enum.join(List.duplicate(String.duplicate("a", 100), 11), "/"), :too_long}
        ] do
      test name do
        assert Destination.resolve(unquote(destination), @base) ==
                 {:error, {:invalid_destination, unquote(reason)}}
      end
    end

    test "a relative base directory" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> Destination.resolve("a", "relative") end
    end
  end
end
