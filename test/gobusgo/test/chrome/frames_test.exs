defmodule Gobusgo.Test.Chrome.FramesTest do
  # Splits byte buffers in the forms a pipe delivers them: whole messages,
  # a message cut in two, and nothing at all.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.Chrome.Frames

  describe "split/1" do
    test "returns each terminated message and an empty rest" do
      assert Frames.split(<<"{\"id\":1}", 0, "{\"id\":2}", 0>>) ==
               {["{\"id\":1}", "{\"id\":2}"], ""}
    end

    test "keeps the bytes after the last terminator as the rest" do
      assert Frames.split(<<"{\"id\":1}", 0, "{\"id\"">>) == {["{\"id\":1}"], "{\"id\""}
    end

    test "returns no message for a buffer with no terminator" do
      assert Frames.split("{\"id\"") == {[], "{\"id\""}
    end

    test "returns no message for an empty buffer" do
      assert Frames.split("") == {[], ""}
    end
  end

  describe "frame/1" do
    test "terminates a message so that split/1 returns it" do
      assert Frames.split(Frames.frame("{\"id\":1}")) == {["{\"id\":1}"], ""}
    end
  end
end
