defmodule Gobusgo.Test.FeatureLayer do
  @moduledoc """
  A plug that answers as an ArcGIS FeatureServer layer answers: its
  description with `lastEditDate`, its count, and pages of its features
  above the `OBJECTID` a `where` names, with `exceededTransferLimit` on a
  page that leaves features after it. Each request is sent to `test_pid` as
  `{:request, request_path, query_params}` and its host as `{:host, host}`.
  `script`, given the connection,
  answers `{status, body}` in place of the layer, or `:default`.
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
      send(test_pid, {:request, conn.request_path, conn.query_params})
      send(test_pid, {:host, conn.host})

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

      %{"where" => "OBJECTID>" <> last, "resultRecordCount" => size} ->
        last_object_id = String.to_integer(last)
        above = Enum.filter(features, &(&1["attributes"]["OBJECTID"] > last_object_id))
        page = Enum.take(above, String.to_integer(size))
        send_resp(conn, 200, JSON.encode!(page_body(page, length(above) > length(page))))
    end
  end

  defp page_body(page, true), do: %{"features" => page, "exceededTransferLimit" => true}
  defp page_body(page, false), do: %{"features" => page}
end
