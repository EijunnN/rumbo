defmodule RumboWeb.TripChannel do
  @moduledoc """
  Canal `trip:<id>` (solo lectura). Eventos:

    * `"position"` — posición del tracker del trip
    * `"eta"` — ETA recalculado (total y por waypoint en `legs`)
    * `"status"` — ciclo de vida del trip (completed/canceled, cambios de ruta)
    * `"tracker_status"` — online/offline del tracker

  Cada miembro cuenta como espectador del trip: su presencia dispara el
  evento `watchers` hacia el dispositivo, que sube la cadencia de GPS solo
  mientras alguien mira.

  El join responde un snapshot `{trip, position, eta}` para render inmediato.
  """

  use RumboWeb, :channel

  alias Rumbo.Auth.Scope
  alias Rumbo.Projects
  alias Rumbo.Projects.Project
  alias Rumbo.Topics
  alias Rumbo.Trips

  @impl true
  def join("trip:" <> trip_id, _params, socket) do
    with true <- Scope.allows?(socket.assigns.subscribe, "trip:#{trip_id}"),
         %Project{} = project <- Projects.get_project(socket.assigns.project_id),
         {:ok, trip} <- Trips.fetch_trip(project, trip_id) do
      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.trip(project.id, trip.id))

      {:ok, _ref} =
        Rumbo.Presence.track(
          self(),
          Topics.trip_watchers(project.id, trip.id),
          Ecto.UUID.generate(),
          %{}
        )

      snapshot = %{
        trip: RumboWeb.V1.TripJSON.data(trip),
        position: trip.tracker.last_position,
        eta: trip.eta
      }

      {:ok, snapshot, assign(socket, project: project, trip_id: trip.id)}
    else
      _ -> {:error, %{reason: "unauthorized or not found"}}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end
end
