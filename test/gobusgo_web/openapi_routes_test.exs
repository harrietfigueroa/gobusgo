defmodule GobusgoWeb.OpenApiRoutesTest do
  # Keeps the two hand-written OpenAPI documents and the router in step: it
  # lists the operations and the catch-alls of `GobusgoWeb.Router` outside the
  # browser pages, reads the documents with the built-in JSON module, and
  # compares the two sets in both directions, naming each route one side
  # lacks. No body is validated against a schema here.
  #
  # A route the router declares with a verb is an operation, `GET /health`,
  # with a path parameter spelled `{id}` as OpenAPI spells it. A route the
  # router declares with `match :*` serves every method, which a path item
  # cannot state, so a document lists it under the top-level `x-fallbacks`
  # extension by the router's own path, `/api/*path`.
  use ExUnit.Case, async: true

  @documents [
    Path.expand("../../priv/openapi.json", __DIR__),
    Path.expand("../../priv/openapi.private.json", __DIR__)
  ]
  @operation_verbs ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

  defp router_routes do
    for route <- Phoenix.Router.routes(GobusgoWeb.Router),
        not is_map_key(route.metadata, :phoenix_live_view) do
      route
    end
  end

  defp router_operations do
    for %{verb: verb, path: path} <- router_routes(), verb != :*, into: MapSet.new() do
      method = verb |> Atom.to_string() |> String.upcase()
      "#{method} #{openapi_path(path)}"
    end
  end

  defp router_fallbacks do
    for %{verb: :*, path: path} <- router_routes(), into: MapSet.new() do
      path
    end
  end

  defp openapi_path(path) do
    Regex.replace(~r/:([a-z_]+)/, path, "{\\1}")
  end

  defp documents do
    for path <- @documents do
      path |> File.read!() |> JSON.decode!()
    end
  end

  defp document_operations do
    for document <- documents(),
        {path, item} <- Map.fetch!(document, "paths"),
        {verb, _operation} <- item,
        verb in @operation_verbs,
        into: MapSet.new() do
      "#{String.upcase(verb)} #{path}"
    end
  end

  defp document_fallbacks do
    for document <- documents(),
        %{"path" => path} <- Map.get(document, "x-fallbacks", []),
        into: MapSet.new() do
      path
    end
  end

  defp names(set), do: set |> Enum.sort() |> Enum.join(", ")

  test "the documents exist" do
    for path <- @documents do
      assert File.regular?(path), "#{path} is missing"
    end
  end

  test "every router operation is in a document" do
    missing = MapSet.difference(router_operations(), document_operations())
    assert MapSet.size(missing) == 0, "the documents lack the routes: #{names(missing)}"
  end

  test "every document operation is a router route" do
    unserved = MapSet.difference(document_operations(), router_operations())

    assert MapSet.size(unserved) == 0,
           "the documents name routes the router lacks: #{names(unserved)}"
  end

  test "every router catch-all is an x-fallbacks entry of a document" do
    missing = MapSet.difference(router_fallbacks(), document_fallbacks())
    assert MapSet.size(missing) == 0, "the documents lack the catch-alls: #{names(missing)}"
  end

  test "every x-fallbacks entry of a document is a router catch-all" do
    unserved = MapSet.difference(document_fallbacks(), router_fallbacks())

    assert MapSet.size(unserved) == 0,
           "the documents name catch-alls the router lacks: #{names(unserved)}"
  end
end
