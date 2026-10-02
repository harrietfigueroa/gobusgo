defmodule Gobusgo.LocalFile.LocationTest do
  # Verifies placement of validated segments under a base directory as a pure
  # function of the segment list and the base.
  use ExUnit.Case, async: true

  alias Gobusgo.LocalFile.Location

  test "joins the segments under the base directory" do
    assert Location.place(["raw", "a.json"], "/var/data") == {:ok, "/var/data/raw/a.json"}
  end

  test "raises for a relative base directory" do
    assert_raise Gobusgo.Assert.AssertionError, fn -> Location.place(["a"], "relative") end
  end
end
