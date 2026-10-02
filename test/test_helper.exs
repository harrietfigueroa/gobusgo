# Tests tagged :kafka need a running broker; `mix test --include kafka` runs them.
ExUnit.start(exclude: [:kafka])
