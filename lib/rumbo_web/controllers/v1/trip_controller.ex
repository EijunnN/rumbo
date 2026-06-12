defmodule RumboWeb.V1.TripController do
  use RumboWeb, :controller

  alias Rumbo.Trips

  action_fallback RumboWeb.V1.FallbackController

  def create(conn, params) do
    with {:ok, trip} <- Trips.create_trip(conn.assigns.project, params) do
      conn
      |> put_status(:created)
      |> render(:show, trip: trip)
    end
  end

  def index(conn, params) do
    filters = %{status: params["status"], tracker: params["tracker"]}
    render(conn, :index, trips: Trips.list_trips(conn.assigns.project, filters))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, trip} <- Trips.fetch_trip(conn.assigns.project, id) do
      render(conn, :show, trip: trip)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, trip} <- Trips.update_trip(conn.assigns.project, id, Map.delete(params, "id")) do
      render(conn, :show, trip: trip)
    end
  end
end
