defmodule RumboWeb.TrackerChannel do
  @moduledoc """
  Canal `tracker:<key>`.

  Suscriptores (scope subscribe) reciben:

    * `"position"` — cada posición nueva
    * `"status"` — transiciones online/offline
    * `"trip"` — trips creados/actualizados para este tracker

  Publicadores (scope publish) pueden hacer push de `"position"` con un punto
  o `{"positions": [...]}`, equivalente al ingest HTTP pero sobre el socket.

  El join responde un snapshot con el último estado conocido para que el
  cliente pinte el mapa sin esperar al primer evento.
  """

  use RumboWeb, :channel

  alias Rumbo.Auth.Scope
  alias Rumbo.Projects
  alias Rumbo.Projects.Project
  alias Rumbo.Topics
  alias Rumbo.Tracking

  @impl true
  def join("tracker:" <> tracker_key, _params, socket) do
    topic = "tracker:#{tracker_key}"
    can_subscribe = Scope.allows?(socket.assigns.subscribe, topic)
    can_publish = Scope.allows?(socket.assigns.publish, topic)

    with true <- can_subscribe or can_publish,
         %Project{} = project <- Projects.get_project(socket.assigns.project_id) do
      if can_subscribe do
        Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.tracker(project.id, tracker_key))
      end

      socket =
        assign(socket, project: project, tracker_key: tracker_key, can_publish: can_publish)

      {:ok, snapshot(project, tracker_key), socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("position", payload, socket) do
    if socket.assigns.can_publish do
      positions = extract_positions(payload)

      case Tracking.ingest(socket.assigns.project, socket.assigns.tracker_key, positions) do
        {:ok, result} ->
          {:reply, {:ok, result}, socket}

        {:error, reason} ->
          {:reply, {:error, format_error(reason)}, socket}
      end
    else
      {:reply, {:error, %{reason: "publish scope required"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown event"}}, socket}
  end

  # Eventos internos de PubSub → push directo al cliente.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  defp snapshot(project, tracker_key) do
    case Tracking.get_tracker(project, tracker_key) do
      nil ->
        %{tracker: %{key: tracker_key, position: nil, online: false, last_seen_at: nil}}

      tracker ->
        %{tracker: RumboWeb.V1.TrackerJSON.data(tracker, project)}
    end
  end

  defp extract_positions(%{"positions" => positions}) when is_list(positions), do: positions
  defp extract_positions(payload) when is_map(payload), do: [payload]
  defp extract_positions(_), do: []

  defp format_error({:invalid_position, index, changeset}) do
    %{reason: "invalid position at index #{index}", errors: changeset_errors(changeset)}
  end

  defp format_error(reason) when is_atom(reason), do: %{reason: to_string(reason)}
  defp format_error(_), do: %{reason: "invalid payload"}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
