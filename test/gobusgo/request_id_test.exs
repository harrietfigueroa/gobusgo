defmodule Gobusgo.RequestIdTest do
  # Verifies the UUID version 7 layout through build/1 with fixed parts, and
  # generate/0 through the properties its output must hold.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.RequestId

  @unix_ms 0x0199C4A27E1B

  describe "build/1" do
    for {name, random_byte, expected} <- [
          {"all random bits clear", 0x00, "0199c4a2-7e1b-7000-8000-000000000000"},
          {"all random bits set", 0xFF, "0199c4a2-7e1b-7fff-bfff-ffffffffffff"}
        ] do
      test "places the timestamp, version, and variant with #{name}" do
        random = :binary.copy(<<unquote(random_byte)>>, 10)

        assert RequestId.build(%{unix_ms: @unix_ms, random: random}) == unquote(expected)
      end
    end

    test "raises for a timestamp wider than 48 bits" do
      assert_raise AssertionError, ~r/unix_ms/, fn ->
        RequestId.build(%{unix_ms: 0x1_0000_0000_0000, random: :binary.copy(<<0>>, 10)})
      end
    end

    test "raises for a negative timestamp" do
      assert_raise AssertionError, ~r/unix_ms/, fn ->
        RequestId.build(%{unix_ms: -1, random: :binary.copy(<<0>>, 10)})
      end
    end
  end

  describe "generate/0" do
    test "returns a valid identifier" do
      assert RequestId.valid?(RequestId.generate())
    end

    test "returns a different identifier on each call" do
      assert RequestId.generate() != RequestId.generate()
    end
  end

  describe "valid?/1" do
    for {name, candidate, expected} <- [
          {"a version 7 identifier", "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10", true},
          {"a version 4 identifier", "0199c4a2-7e1b-4a3f-9d20-5b6c1e8f4a10", false},
          {"a reserved variant", "0199c4a2-7e1b-7a3f-cd20-5b6c1e8f4a10", false},
          {"uppercase digits", "0199C4A2-7E1B-7A3F-9D20-5B6C1E8F4A10", false},
          {"a trailing newline", "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10\n", false},
          {"an empty string", "", false}
        ] do
      test "is #{expected} for #{name}" do
        assert RequestId.valid?(unquote(candidate)) == unquote(expected)
      end
    end
  end
end
