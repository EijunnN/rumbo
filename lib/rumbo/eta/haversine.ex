defmodule Rumbo.Eta.Haversine do
  @moduledoc """
  Motor de ETA por defecto, sin dependencias externas.

  Estima cada pierna como distancia de gran círculo multiplicada por un factor
  de circuito (las calles no son líneas rectas; 1.3 es un valor típico
  urbano). La duración usa la velocidad suavizada del tracker cuando se está
  moviendo, o la velocidad de crucero configurada como fallback.
  """

  @behaviour Rumbo.Eta.Engine

  alias Rumbo.Geo

  @impl true
  def route(from, waypoints, opts) do
    settings = Keyword.fetch!(opts, :settings)
    speed_mps = effective_speed(opts[:speed_mps], settings)

    {legs, _last} =
      Enum.map_reduce(waypoints, from, fn point, previous ->
        distance = Geo.haversine_meters(previous, point) * settings.circuity
        {%{distance_meters: distance, duration_seconds: distance / speed_mps}, point}
      end)

    {:ok,
     %{
       distance_meters: legs |> Enum.map(& &1.distance_meters) |> Enum.sum(),
       duration_seconds: legs |> Enum.map(& &1.duration_seconds) |> Enum.sum(),
       legs: legs
     }}
  end

  # Velocidades por debajo de min_speed_kmh (semáforo, parada) producirían
  # ETAs absurdos, así que ahí se usa la velocidad de crucero del proyecto.
  defp effective_speed(speed_mps, settings) do
    if is_number(speed_mps) and speed_mps * 3.6 >= settings.min_speed_kmh do
      speed_mps
    else
      settings.fallback_speed_kmh / 3.6
    end
  end
end
