defmodule RumboWeb.V1.TripJSON do
  alias Rumbo.Geo

  def index(%{trips: trips}), do: %{data: Enum.map(trips, &data/1)}

  def show(%{trip: trip}), do: %{data: data(trip)}

  def data(trip) do
    %{
      id: trip.id,
      tracker: trip.tracker.key,
      status: trip.status,
      destination: Geo.normalize_point!(trip.destination),
      waypoints: Enum.map(trip.waypoints, &Geo.normalize_point!/1),
      metadata: trip.metadata,
      eta: trip.eta,
      started_at: trip.started_at,
      ended_at: trip.ended_at,
      created_at: trip.inserted_at
    }
  end
end
