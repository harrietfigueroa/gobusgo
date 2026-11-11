defmodule GobusgoWeb.Mcp.Resource do
  @moduledoc """
  The contract of a resource the MCP endpoint serves. A module that
  implements it and is named in the `:resources` of the `GobusgoWeb.Mcp`
  application environment is listed by `resources/list` and answers
  `resources/read`; the endpoint changes for none.

  `definition/0` is the resource as `resources/list` shows it: a map with the
  string keys `"uri"`, `"name"`, `"description"`, and `"mimeType"`. The uri is
  unique among the resources of the registry and is the order the list
  answers in.

  `read/0` returns `{:ok, text}`, the resource's text content, or
  `{:error, :unavailable}` while its source holds nothing to read yet, which
  the endpoint answers as an internal error.
  """

  @callback definition() :: %{required(String.t()) => String.t()}
  @callback read() :: {:ok, String.t()} | {:error, :unavailable}
end
