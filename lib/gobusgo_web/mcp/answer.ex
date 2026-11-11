defmodule GobusgoWeb.Mcp.Answer do
  @item_count_max 100

  @moduledoc """
  What the transit tools share of an answer: the REST body shape, `data`
  and `meta`, with `meta.fetchedAt` and `meta.requestId` naming the fetch
  the data comes from; the tool result that carries it as
  `structuredContent` and as JSON text; and the description every tool
  opens with. Everything here is pure.

  A tool answer holds at most #{@item_count_max} items in each list.
  """

  alias Gobusgo.Assert
  alias GobusgoWeb.Mcp.ServerInfo

  @meta_schema {:map,
                %{
                  "fetchedAt" => {:nullable, :string},
                  "requestId" => {:nullable, :string},
                  "count" => :integer
                }}

  @answer_schema {:map, %{"data" => {:map, %{}}, "meta" => @meta_schema}}

  @doc "The most items a tool answer holds in one list."
  @spec item_count_max() :: pos_integer()
  def item_count_max, do: @item_count_max

  @doc """
  The tool result for `answer`, a map with `data` and `meta`: the answer as
  `structuredContent`, and the same answer as the text of one content block
  for a client that reads only the content.
  """
  @spec result(%{required(String.t()) => term()}) :: {:ok, GobusgoWeb.Mcp.Tool.result()}
  def result(answer) when is_map(answer) do
    Assert.schema(answer, @answer_schema)

    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => JSON.encode!(answer)}],
       "structuredContent" => answer
     }}
  end

  @doc """
  `meta` for `count` items from `fetch`, a map with `fetched_at` and
  `request_id`, or from no fetch for `nil`. `extra` adds fields.
  """
  @spec meta(%{
          fetch: %{fetched_at: DateTime.t(), request_id: String.t()} | nil,
          count: non_neg_integer(),
          extra: %{required(String.t()) => term()}
        }) :: %{required(String.t()) => term()}
  def meta(%{fetch: fetch, count: count, extra: extra}) do
    {fetched_at, request_id} =
      case fetch do
        nil -> {nil, nil}
        %{fetched_at: fetched_at, request_id: request_id} -> {iso(fetched_at), request_id}
      end

    Map.merge(%{"fetchedAt" => fetched_at, "requestId" => request_id, "count" => count}, extra)
  end

  @doc "`datetime` in UTC extended ISO 8601, as the REST answers write it."
  @spec iso(DateTime.t()) :: String.t()
  def iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime, :extended)

  @doc """
  `purpose` followed by the credit and the link to the data terms, which
  every live-data tool carries.
  """
  @spec description(String.t()) :: String.t()
  def description(purpose) when is_binary(purpose), do: purpose <> " " <> ServerInfo.credit()

  @doc "The `outputSchema` of an answer whose `data` is `data_schema`, a JSON Schema."
  @spec output_schema(map()) :: map()
  def output_schema(data_schema) when is_map(data_schema) do
    %{
      "type" => "object",
      "properties" => %{
        "data" => data_schema,
        "meta" => %{
          "type" => "object",
          "properties" => %{
            "fetchedAt" => %{"type" => ["string", "null"], "format" => "date-time"},
            "requestId" => %{"type" => ["string", "null"]},
            "count" => %{"type" => "integer"}
          },
          "required" => ["fetchedAt", "requestId", "count"]
        }
      },
      "required" => ["data", "meta"]
    }
  end
end
