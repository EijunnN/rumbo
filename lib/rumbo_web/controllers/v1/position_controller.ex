defmodule RumboWeb.V1.PositionController do
  use RumboWeb, :controller

  alias Rumbo.Tracking

  action_fallback RumboWeb.V1.FallbackController

  @doc """
  Ingesta de posiciones. Tres formas equivalentes, todas → 202:

      POST /v1/trackers/driver_42/positions {"lat": .., "lng": ..}
      POST /v1/trackers/driver_42/positions {"positions": [{...}, {...}]}
      POST /v1/positions {"tracker": "driver_42", "positions": [{...}]}
  """
  def create(conn, params) do
    tracker_key = params["key"] || params["tracker"]

    with {:ok, result} <- Tracking.ingest(conn.assigns.project, tracker_key, extract(params)) do
      conn
      |> put_status(:accepted)
      |> render(:accepted, result: result)
    end
  end

  @doc "GET /v1/trackers/:key/positions?from=&to=&limit= — historial, recientes primero."
  def index(conn, %{"key" => key} = params) do
    with {:ok, opts} <- history_opts(params),
         {:ok, positions} <- Tracking.list_positions(conn.assigns.project, key, opts) do
      render(conn, :index, positions: positions)
    end
  end

  defp extract(%{"positions" => positions}) when is_list(positions), do: positions
  defp extract(%{"position" => position}) when is_map(position), do: [position]
  defp extract(params) when is_map(params), do: [Map.drop(params, ["key", "tracker"])]

  defp history_opts(params) do
    with {:ok, from} <- parse_datetime(params["from"], "from"),
         {:ok, to} <- parse_datetime(params["to"], "to"),
         {:ok, limit} <- parse_limit(params["limit"]) do
      {:ok, Enum.reject([from: from, to: to, limit: limit], fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp parse_datetime(nil, _name), do: {:ok, nil}

  defp parse_datetime(value, name) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, {:invalid_param, name}}
    end
  end

  defp parse_limit(nil), do: {:ok, nil}

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {limit, ""} when limit > 0 -> {:ok, limit}
      _ -> {:error, {:invalid_param, "limit"}}
    end
  end
end
