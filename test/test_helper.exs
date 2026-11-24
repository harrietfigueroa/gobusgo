# Tests tagged :memory print a measurement; `mix test --only memory` runs them.
# Tests tagged :core_pages drive the pages in three browsers; `mix test --only
# core_pages` runs them alone, and only then are the browsers and the
# listener started, since the check serves the endpoint and fills the views
# the other tests expect untouched.

# ExUnit holds each filter as a tag or as a tag and its value, and `--only`
# excludes every test, `:test`, beside including its tag.
filter_tags = fn key ->
  for filter <- Keyword.get(ExUnit.configuration(), key, []) do
    case filter do
      {tag, _value} -> tag
      tag -> tag
    end
  end
end

is_core_pages_only = :core_pages in filter_tags.(:include) and :test in filter_tags.(:exclude)

if is_core_pages_only do
  {:ok, _supervisor} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, Gobusgo.Test.CorePages.Server.serve())
end

ExUnit.start(exclude: [:memory, :core_pages])
