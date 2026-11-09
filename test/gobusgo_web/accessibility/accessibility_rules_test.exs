defmodule GobusgoWeb.AccessibilityRulesTest do
  # Checks each rule of Gobusgo.Test.Accessibility against a small document
  # that breaks it and one that keeps it, so a rule that stops finding its
  # failure fails here before it lets a page through.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.Accessibility

  defp document(body, options \\ []) do
    language = Keyword.get(options, :lang, ~s( lang="en"))
    title = Keyword.get(options, :title, "<title>Page</title>")

    ~s(<!DOCTYPE html><html#{language}><head>#{title}</head><body><main>#{body}</main></body></html>)
  end

  defp rules(html), do: html |> Accessibility.violations() |> Enum.map(&elem(&1, 0))

  test "a document that keeps every rule has no violation" do
    html =
      document(~s"""
      <button type="button">Save</button>
      <a href="/x" aria-label="Next page">→</a>
      <label for="q">Search</label><input id="q" type="text">
      <label>Remember <input type="checkbox"></label>
      <button type="button" aria-labelledby="t"><svg aria-hidden="true"></svg></button>
      <h2 id="t">Close</h2>
      <a href="/y"><img src="/i.png" alt="Home"></a>
      """)

    assert Accessibility.violations(html) == []
  end

  test "a document with no lang breaks the language rule" do
    assert rules(document("", lang: "")) == [:language]
  end

  test "a document with an empty title breaks the title rule" do
    assert rules(document("", title: "<title> </title>")) == [:title]
  end

  test "a document with two main elements breaks the main rule" do
    assert rules(document("<main>again</main>")) == [:main]
  end

  test "a reference to an identifier no element has breaks the reference rule" do
    assert rules(document(~s(<p aria-describedby="nowhere">x</p>))) == [:reference]
  end

  test "a hidden element may name an identifier the browser writes before it shows it" do
    assert rules(document(~s(<section hidden aria-labelledby="later"></section>))) == []
  end

  for {case_name, body} <- [
        {"an empty button", ~s(<button type="button"></button>)},
        {"a button whose only content is hidden",
         ~s(<button type="button"><span aria-hidden="true">×</span></button>)},
        {"a link with an image and no alt", ~s(<a href="/x"><img src="/i.png"></a>)},
        {"an input with no label", ~s(<input type="text">)},
        {"a tab with no text", ~s(<div role="tab"></div>)}
      ] do
    test "#{case_name} breaks the name rule" do
      assert rules(document(unquote(body))) == [:name]
    end
  end
end
