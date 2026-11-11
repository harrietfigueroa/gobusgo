defmodule GobusgoWeb.Mcp.Tool do
  @moduledoc """
  The contract of a tool the MCP endpoint serves. A module that implements it
  and is named in the `:tools` of the `GobusgoWeb.Mcp` application
  environment is listed by `tools/list` and answers `tools/call`; the
  endpoint changes for none.

  `definition/0` is the tool as `tools/list` shows it: a map with the string
  keys `"name"`, `"description"`, and `"inputSchema"`, a JSON Schema object,
  and optionally `"title"` and `"outputSchema"`. The name is unique among the
  tools of the registry and is the order `tools/list` answers in.

  `arguments_schema/0` is the same input as a `Gobusgo.Schema`, which the
  endpoint checks the arguments of a call against before it calls the tool,
  so `call/1` receives a map that matches. A call whose arguments do not
  match is answered with invalid params and never reaches the tool.

  `call/1` returns `{:ok, result}`, where `result` holds the string keys
  `"content"`, a list of content blocks, and optionally `"structuredContent"`,
  or `{:error, text}` for a failure the model can act on, which the endpoint
  answers as a result flagged `isError`. A tool returns a known outcome as a
  value and raises only for a bug.
  """

  @type result :: %{required(String.t()) => term()}

  @callback definition() :: %{required(String.t()) => term()}
  @callback arguments_schema() :: Gobusgo.Schema.t()
  @callback call(arguments :: %{required(String.t()) => term()}) ::
              {:ok, result()} | {:error, String.t()}
end
