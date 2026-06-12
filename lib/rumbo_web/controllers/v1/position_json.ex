defmodule RumboWeb.V1.PositionJSON do
  def accepted(%{result: result}), do: %{data: result}

  def index(%{positions: positions}) do
    %{data: Enum.map(positions, &data/1)}
  end

  def data(position) do
    %{
      lat: position.lat,
      lng: position.lng,
      speed: position.speed,
      heading: position.heading,
      accuracy: position.accuracy,
      altitude: position.altitude,
      battery: position.battery,
      metadata: position.metadata,
      recorded_at: position.recorded_at
    }
  end
end
