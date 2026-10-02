defmodule Gobusgo.Writer.DestinationTest do
  # Verifies logical destination validation as a pure function of the
  # destination string.
  use ExUnit.Case, async: true

  alias Gobusgo.Writer.Destination

  describe "validate/1 accepts" do
    test "a single segment" do
      assert Destination.validate("a.json") == {:ok, ["a.json"]}
    end

    test "the partitioned layout with equals signs and underscores" do
      destination =
        "raw/oba/agencies-with-coverage/dt=2026-10-02/20261002T031500Z_0199c4a2_3f9a1c07be52.json"

      assert {:ok, segments} = Destination.validate(destination)
      assert length(segments) == 5
    end
  end

  describe "validate/1 rejects" do
    for {name, destination, reason} <- [
          {"an empty string", "", :empty},
          {"a leading slash", "/etc/passwd", :absolute},
          {"a dot-dot segment", "a/../b", :traversal},
          {"a leading dot-dot", "../escape", :traversal},
          {"a lone dot segment", "a/./b", :traversal},
          {"a leading dot", ".hidden", :segment_invalid},
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
        assert Destination.validate(unquote(destination)) ==
                 {:error, {:invalid_destination, unquote(reason)}}
      end
    end
  end
end
