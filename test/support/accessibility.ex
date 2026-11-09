defmodule Gobusgo.Test.Accessibility do
  @moduledoc """
  The accessibility rules a rendered HTML document can break that
  html-eslint has no rule for, as pure functions over the document. Each
  rule returns its violations as values, `{rule, detail}`, so a test names
  every one it finds at once.

  The accessible name follows the parts of the W3C Accessible Name and
  Description Computation that the server's markup uses: `aria-labelledby`,
  `aria-label`, a `<label>` for or around a form control, the text content
  of a button, a link, or a summary, an image's `alt`, and `title`.
  https://www.w3.org/TR/accname-1.2/ — checked 2026-11-09
  """

  @type violation :: {atom(), String.t()}

  # The elements a rider can focus or operate, which each need a name.
  @interactive_selector Enum.join(
                          [
                            "a[href]",
                            "button",
                            "input:not([type=hidden])",
                            "select",
                            "textarea",
                            "summary",
                            "[role=button]",
                            "[role=link]",
                            "[role=tab]",
                            "[role=tabpanel]",
                            "[role=checkbox]",
                            "[role=radio]",
                            "[role=switch]",
                            "[role=combobox]",
                            "[role=listbox]",
                            "[role=option]",
                            "[role=menuitem]"
                          ],
                          ", "
                        )

  # The attributes whose value is a list of identifiers in the same
  # document.
  @reference_attributes ["aria-labelledby", "aria-describedby", "aria-controls", "for"]

  @doc "Every violation of every rule in the document `html`, in rule order."
  @spec violations(String.t()) :: [violation()]
  def violations(html) when is_binary(html) do
    document = LazyHTML.from_document(html)

    language_violations(document) ++
      title_violations(document) ++
      main_violations(document) ++
      reference_violations(document) ++
      name_violations(document)
  end

  @doc "The root element carries a `lang` attribute."
  @spec language_violations(LazyHTML.t()) :: [violation()]
  def language_violations(document) do
    case LazyHTML.attribute(LazyHTML.query(document, "html"), "lang") do
      [language] when language != "" -> []
      _missing -> [{:language, "the html element has no lang"}]
    end
  end

  @doc "The document has one `<title>`, with text."
  @spec title_violations(LazyHTML.t()) :: [violation()]
  def title_violations(document) do
    titles = LazyHTML.query(document, "head title")

    case Enum.map(titles, &squished_text/1) do
      [title] when title != "" -> []
      found -> [{:title, "expected one title with text, found #{inspect(found)}"}]
    end
  end

  @doc "The document has exactly one `<main>`."
  @spec main_violations(LazyHTML.t()) :: [violation()]
  def main_violations(document) do
    case Enum.count(LazyHTML.query(document, "main")) do
      1 -> []
      count -> [{:main, "expected one main element, found #{count}"}]
    end
  end

  @doc """
  Every identifier an `aria-labelledby`, `aria-describedby`,
  `aria-controls`, or a label's `for` names is an element of the document.
  An element that is `hidden` is passed over: it is out of the
  accessibility tree, and the browser writes the element it names before
  it shows it, as the panel sheet's details view does with its title.
  """
  @spec reference_violations(LazyHTML.t()) :: [violation()]
  def reference_violations(document) do
    for attribute <- @reference_attributes,
        element <- LazyHTML.query(document, "[#{attribute}]:not([hidden])"),
        [value] = LazyHTML.attribute(element, attribute),
        id <- String.split(value),
        Enum.empty?(LazyHTML.query_by_id(document, id)) do
      {:reference, "#{describe(element)} names #{attribute}=#{id}, which no element has"}
    end
  end

  @doc "Every element a rider can focus or operate has an accessible name."
  @spec name_violations(LazyHTML.t()) :: [violation()]
  def name_violations(document) do
    for element <- LazyHTML.query(document, @interactive_selector),
        accessible_name(document, element) == "" do
      {:name, "#{describe(element)} has no accessible name"}
    end
  end

  @doc "The accessible name of `element` in `document`, squished."
  @spec accessible_name(LazyHTML.t(), LazyHTML.t()) :: String.t()
  def accessible_name(document, element) do
    first_present([
      fn -> labelled_by_name(document, element) end,
      fn -> attribute_value(element, "aria-label") end,
      fn -> label_name(document, element) end,
      fn -> content_name(element) end,
      fn -> attribute_value(element, "title") end
    ])
  end

  defp first_present([]), do: ""

  defp first_present([candidate | rest]) do
    case candidate.() do
      "" -> first_present(rest)
      name -> name
    end
  end

  defp labelled_by_name(document, element) do
    element
    |> attribute_value("aria-labelledby")
    |> String.split()
    |> Enum.map_join(" ", fn id -> document |> LazyHTML.query_by_id(id) |> squished_text() end)
    |> String.trim()
  end

  # A form control is named by a label that names it with `for`, or by a
  # label around it.
  defp label_name(document, element) do
    tag = LazyHTML.tag(element)
    is_form_control = tag in [["input"], ["select"], ["textarea"]]

    if is_form_control do
      for_name =
        case LazyHTML.attribute(element, "id") do
          [id] -> document |> LazyHTML.query("label[for=\"#{id}\"]") |> squished_text()
          [] -> ""
        end

      first_present([fn -> for_name end, fn -> enclosing_label_name(element) end])
    else
      ""
    end
  end

  defp enclosing_label_name(element) do
    parent = LazyHTML.parent_node(element)

    cond do
      Enum.empty?(parent) -> ""
      LazyHTML.tag(parent) == ["label"] -> squished_text(parent)
      true -> enclosing_label_name(parent)
    end
  end

  # Buttons, links, summaries, and roles that take their name from content
  # read their text, less what is hidden from assistive technology, and the
  # `alt` of their images. An input button reads its `value`.
  defp content_name(element) do
    case LazyHTML.tag(element) do
      ["input"] ->
        attribute_value(element, "value")

      [tag] when tag in ["select", "textarea"] ->
        ""

      _content ->
        visible =
          element
          |> LazyHTML.to_tree()
          |> without_hidden()
          |> LazyHTML.from_tree()

        text = squished_text(visible)
        alts = visible |> LazyHTML.query("img[alt]") |> LazyHTML.attribute("alt")
        Enum.join([text | alts], " ") |> String.trim()
    end
  end

  defp without_hidden(tree) when is_list(tree) do
    for node <- tree, keep?(node), do: without_hidden(node)
  end

  defp without_hidden({tag, attributes, children}),
    do: {tag, attributes, without_hidden(children)}

  defp without_hidden(other), do: other

  defp keep?({_tag, attributes, _children}),
    do: not Enum.any?(attributes, &(&1 == {"aria-hidden", "true"}))

  defp keep?(_text_or_comment), do: true

  defp attribute_value(element, name) do
    case LazyHTML.attribute(element, name) do
      [value] -> String.trim(value)
      [] -> ""
    end
  end

  defp squished_text(element) do
    element |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end

  defp describe(element) do
    [tag] = LazyHTML.tag(element)

    case LazyHTML.attribute(element, "id") do
      [id] -> "<#{tag} id=#{id}>"
      [] -> "<#{tag}> " <> String.slice(LazyHTML.to_html(element), 0, 120)
    end
  end
end
