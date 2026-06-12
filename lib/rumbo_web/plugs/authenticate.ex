defmodule RumboWeb.Plugs.Authenticate do
  @moduledoc """
  Autenticación por API key de servidor: `Authorization: Bearer rk_...`.
  Deja el proyecto en `conn.assigns.project`.
  """

  import Plug.Conn

  alias Rumbo.Projects

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> raw_key] <- get_req_header(conn, "authorization"),
         {:ok, project} <- Projects.authenticate_api_key(String.trim(raw_key)) do
      assign(conn, :project, project)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          error: %{
            code: "unauthorized",
            message: "Provide a valid API key via the Authorization: Bearer rk_... header"
          }
        })
        |> halt()
    end
  end
end
