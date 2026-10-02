defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots and its supervisor is alive.
  use ExUnit.Case, async: true

  test "the supervision tree is running" do
    assert is_pid(Process.whereis(Gobusgo.Supervisor))
  end
end
