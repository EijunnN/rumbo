defmodule RumboWeb.V1.TokenController do
  use RumboWeb, :controller

  alias Rumbo.Auth.{ClientToken, Scope}

  action_fallback RumboWeb.V1.FallbackController

  @doc """
  POST /v1/tokens — emite un token efímero para clientes finales:

      {"subscribe": ["trip:<id>"], "publish": ["tracker:driver_42"], "ttl_seconds": 3600}
  """
  def create(conn, params) do
    subscribe = List.wrap(params["subscribe"] || [])
    publish = List.wrap(params["publish"] || [])

    with :ok <- validate_scopes(subscribe ++ publish),
         {:ok, ttl} <- parse_ttl(params["ttl_seconds"]) do
      {token, expires_at} =
        ClientToken.issue(conn.assigns.project,
          subscribe: subscribe,
          publish: publish,
          ttl_seconds: ttl
        )

      conn
      |> put_status(:created)
      |> render(:show,
        token: token,
        expires_at: expires_at,
        subscribe: subscribe,
        publish: publish
      )
    end
  end

  defp validate_scopes([]), do: {:error, :invalid_scopes}

  defp validate_scopes(scopes) do
    if Enum.all?(scopes, &Scope.valid?/1), do: :ok, else: {:error, :invalid_scopes}
  end

  defp parse_ttl(nil), do: {:ok, nil}
  defp parse_ttl(ttl) when is_integer(ttl) and ttl > 0, do: {:ok, ttl}
  defp parse_ttl(_), do: {:error, {:invalid_param, "ttl_seconds"}}
end
