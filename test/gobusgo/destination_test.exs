defmodule Gobusgo.DestinationTest do
  # Verifies logical destination and prefix validation as pure functions of
  # the input string, with a table of rejected inputs per function.
  use ExUnit.Case, async: true

  alias Gobusgo.Destination

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

  describe "validate_prefix/1 accepts" do
    for {name, prefix, segments, remainder} <- [
          {"a partial first segment", "ra", [], "ra"},
          {"a complete level ending in a slash", "raw/", ["raw"], ""},
          {"a partition ending in a slash", "raw/oba/dt=2026-10-02/",
           ["raw", "oba", "dt=2026-10-02"], ""},
          {"a partial name below complete levels", "processed/20261002T000000Z-20261003T000000Z_",
           ["processed"], "20261002T000000Z-20261003T000000Z_"},
          {"a whole destination", "raw/a.json", ["raw"], "a.json"}
        ] do
      test name do
        assert Destination.validate_prefix(unquote(prefix)) ==
                 {:ok, %{segments: unquote(segments), remainder: unquote(remainder)}}
      end
    end
  end

  describe "validate_prefix/1 rejects" do
    for {name, prefix, reason} <- [
          {"an empty string", "", :empty},
          {"a leading slash", "/raw/", :absolute},
          {"a lone slash", "/", :absolute},
          {"a dot-dot level", "raw/../", :traversal},
          {"a trailing dot-dot", "raw/..", :traversal},
          {"a trailing dot", "raw/.", :traversal},
          {"a hidden trailing name", "raw/.tmp", :segment_invalid},
          {"an empty level", "raw//a", :segment_invalid},
          {"a space", "raw/a b", :segment_invalid},
          {"a NUL byte", "raw/\0", :nul_byte},
          {"invalid UTF-8", <<"raw/", 255>>, :not_utf8},
          {"an overlong trailing name", "raw/" <> String.duplicate("a", 129), :segment_too_long},
          {"too many levels", String.duplicate("a/", 16), :too_deep},
          {"an overlong prefix", String.duplicate(String.duplicate("a", 100) <> "/", 11),
           :too_long}
        ] do
      test name do
        assert Destination.validate_prefix(unquote(prefix)) ==
                 {:error, {:invalid_destination, unquote(reason)}}
      end
    end
  end

  test "segment_count_max/0 is the depth validate/1 accepts" do
    deepest = Enum.join(List.duplicate("a", Destination.segment_count_max()), "/")

    assert {:ok, _segments} = Destination.validate(deepest)
    assert Destination.validate(deepest <> "/a") == {:error, {:invalid_destination, :too_deep}}
  end
end
