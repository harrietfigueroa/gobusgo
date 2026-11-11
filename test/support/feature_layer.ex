defmodule Gobusgo.Test.FeatureLayer do
  @moduledoc """
  A plug that answers as an ArcGIS FeatureServer layer answers: its
  description with `lastEditDate`, its count, and the page of its features
  at a `resultOffset`, at most `resultRecordCount` long. Each request is sent
  to `test_pid` as `{:request, host, request_path, query_params}`. `script`,
  given the connection, answers `{status, body}` in place of the layer, or
  `:default`.
  """

  import Plug.Conn

  @type layer :: %{
          test_pid: pid(),
          path: String.t(),
          last_edit_ms: integer(),
          features: [map()],
          script: (Plug.Conn.t() -> :default | {pos_integer(), iodata()})
        }

  @doc "The plug of `layer`."
  @spec plug(layer()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def plug(%{test_pid: test_pid, script: script} = layer) do
    fn conn ->
      conn = fetch_query_params(conn)
      send(test_pid, {:request, conn.host, conn.request_path, conn.query_params})

      case script.(conn) do
        :default -> answer(conn, layer)
        {status, body} -> send_resp(conn, status, body)
      end
    end
  end

  defp answer(%{request_path: path} = conn, %{path: path, last_edit_ms: last_edit_ms}) do
    send_resp(conn, 200, JSON.encode!(%{"editingInfo" => %{"lastEditDate" => last_edit_ms}}))
  end

  defp answer(conn, %{path: path, features: features}) do
    query_path = path <> "/query"
    %{request_path: ^query_path} = conn

    case conn.query_params do
      %{"returnCountOnly" => "true"} ->
        send_resp(conn, 200, JSON.encode!(%{"count" => length(features)}))

      %{"resultOffset" => offset, "resultRecordCount" => size} ->
        page =
          features
          |> Enum.drop(String.to_integer(offset))
          |> Enum.take(String.to_integer(size))

        send_resp(conn, 200, JSON.encode!(%{"features" => page}))
    end
  end
end
