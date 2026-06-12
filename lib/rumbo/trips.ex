defmodule Rumbo.Trips do
  @moduledoc """
  Contexto de trips: ciclo de vida y notificación al estado vivo del tracker.
  """

  import Ecto.Query

  alias Rumbo.Geo
  alias Rumbo.Projects.Project
  alias Rumbo.Repo
  alias Rumbo.Topics
  alias Rumbo.Tracking
  alias Rumbo.Tracking.TrackerServer
  alias Rumbo.Trips.Trip

  @doc """
  Crea un trip activo para un tracker (creándolo si no existe). Falla con un
  error de changeset si el tracker ya tiene un trip activo.
  """
  def create_trip(%Project{} = project, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, tracker} <- Tracking.get_or_create_tracker(project, attrs["tracker"]),
         {:ok, trip} <-
           %Trip{project_id: project.id, tracker_id: tracker.id}
           |> Trip.create_changeset(attrs)
           |> Repo.insert() do
      trip = %{trip | tracker: tracker}
      notify_tracker(project, trip, tracker)
      {:ok, trip}
    end
  end

  def fetch_trip(%Project{id: project_id}, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id || ""),
         %Trip{} = trip <- Repo.get_by(Trip, id: uuid, project_id: project_id) do
      {:ok, Repo.preload(trip, :tracker)}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_trips(%Project{id: project_id}, filters \\ %{}) do
    query =
      from t in Trip,
        where: t.project_id == ^project_id,
        order_by: [desc: t.inserted_at],
        limit: 100,
        preload: :tracker

    query =
      case filters[:status] do
        nil -> query
        status -> where(query, [t], t.status == ^status)
      end

    case filters[:tracker] do
      nil ->
        Repo.all(query)

      tracker_key ->
        from(t in query, join: tr in assoc(t, :tracker), where: tr.key == ^tracker_key)
        |> Repo.all()
    end
  end

  @doc """
  Actualiza un trip (estado, destino, waypoints, metadata). Difunde el cambio
  en los topics del trip y del tracker, y refresca el TrackerServer para que
  el siguiente ping recalcule el ETA contra la ruta nueva.
  """
  def update_trip(%Project{} = project, id, attrs) do
    with {:ok, trip} <- fetch_trip(project, id),
         {:ok, updated} <- trip |> Trip.update_changeset(attrs) |> Repo.update() do
      updated = %{updated | tracker: trip.tracker}

      Tracking.broadcast!(Topics.trip(project.id, updated.id), "status", status_payload(updated))
      notify_tracker(project, updated, trip.tracker)
      {:ok, updated}
    end
  end

  def get_active_trip(project_id, tracker_id) do
    Repo.one(
      from t in Trip,
        where: t.project_id == ^project_id and t.tracker_id == ^tracker_id,
        where: t.status == "active"
    )
  end

  @doc "Puntos de la ruta en orden: waypoints intermedios y el destino al final."
  def route_points(%Trip{} = trip) do
    Enum.map(trip.waypoints ++ [trip.destination], &Geo.normalize_point!/1)
  end

  @doc "Persiste el último ETA calculado (best effort, lo llama el TrackerServer)."
  def store_eta(%Trip{} = trip, eta_payload) do
    case trip |> Ecto.Changeset.change(eta: eta_payload) |> Repo.update() do
      {:ok, updated} -> %{updated | tracker: trip.tracker}
      {:error, _} -> trip
    end
  end

  defp notify_tracker(project, trip, tracker) do
    Tracking.broadcast!(Topics.tracker(project.id, tracker.key), "trip", %{
      trip_id: trip.id,
      tracker: tracker.key,
      status: trip.status
    })

    TrackerServer.refresh(project.id, tracker.key)
  end

  defp status_payload(trip) do
    %{trip_id: trip.id, status: trip.status, ended_at: trip.ended_at}
  end
end
