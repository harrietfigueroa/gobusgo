# Tests tagged :kafka need a running broker; `mix test --include kafka` runs them.
# Tests tagged :memory print a measurement; `mix test --only memory` runs them.
ExUnit.start(exclude: [:kafka, :memory])
