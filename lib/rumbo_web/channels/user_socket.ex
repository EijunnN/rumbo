defmodule RumboWeb.UserSocket do
  @moduledoc """
  Punto de entrada WebSocket (`/socket`). Dos formas de autenticarse:

    * `{"token": "..."}` — token efímero emitido por `POST /v1/tokens`, con
      scopes de subscribe/publish. Para clientes finales (browser/mobile).
    * `{"api_key": "rk_..."}` — API key de servidor, acceso total al proyecto.
      Solo para backend-to-backend; nunca embeber en un cliente.
  """

  use Phoenix.Socket

  alias Rumbo.Auth.ClientToken
  alias Rumbo.Projects

  channel "tracker:*", RumboWeb.TrackerChannel
  channel "trip:*", RumboWeb.TripChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case ClientToken.verify(token) do
      {:ok, claims} ->
        {:ok,
         assign(socket,
           project_id: claims.project_id,
           subscribe: claims.subscribe,
           publish: claims.publish
         )}

      {:error, _} ->
        :error
    end
  end

  def connect(%{"api_key" => api_key}, socket, _connect_info) when is_binary(api_key) do
    case Projects.authenticate_api_key(api_key) do
      {:ok, project} ->
        {:ok, assign(socket, project_id: project.id, subscribe: ["*"], publish: ["*"])}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Permite desconectar todos los sockets de un proyecto con
  # RumboWeb.Endpoint.broadcast("rumbo_socket:<project_id>", "disconnect", %{})
  @impl true
  def id(socket), do: "rumbo_socket:#{socket.assigns.project_id}"
end
