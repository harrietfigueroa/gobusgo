# Tests tagged :memory print a measurement; `mix test --only memory` runs them.
# Tests tagged :core_pages drive the pages in three browsers; `mix test --only
# core_pages` runs them, and only then are the browsers and the listener
# started.

# ExUnit holds each included filter as a tag or as a tag and its value.
included =
  for filter <- Keyword.get(ExUnit.configuration(), :include, []) do
    case filter do
      {tag, _value} -> tag
      tag -> tag
    end
  end

if :core_pages in included do
  {:ok, _supervisor} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, Gobusgo.Test.CorePages.Server.serve())
end

ExUnit.start(exclude: [:memory, :core_pages])
