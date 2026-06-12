defmodule RumboWeb.V1.TrackerController do
  use RumboWeb, :controller

  alias Rumbo.Tracking

  action_fallback RumboWeb.V1.FallbackController

  def index(conn, _params) do
    project = conn.assigns.project
    render(conn, :index, trackers: Tracking.list_trackers(project), project: project)
  end

  def show(conn, %{"key" => key}) do
    project = conn.assigns.project

    with {:ok, tracker} <- Tracking.fetch_tracker(project, key) do
      render(conn, :show, tracker: tracker, project: project)
    end
  end

  @doc "PUT /v1/trackers/:key — crea o actualiza name/metadata."
  def upsert(conn, %{"key" => key} = params) do
    project = conn.assigns.project

    with {:ok, tracker} <-
           Tracking.upsert_tracker(project, key, Map.take(params, ["name", "metadata"])) do
      render(conn, :show, tracker: tracker, project: project)
    end
  end
end
