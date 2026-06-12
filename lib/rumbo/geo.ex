defmodule Rumbo.Geo do
  @moduledoc """
  Utilidades geográficas: distancia haversine y normalización de puntos.

  Un "punto" es cualquier mapa con coordenadas. La API acepta alias comunes
  (`lat`/`latitude`, `lng`/`lon`/`longitude`) y los normaliza a `%{lat: f, lng: f}`
  preservando `id`, `name` y `metadata` si vienen.
  """

  @earth_radius_m 6_371_000.0

  @doc "Distancia en metros entre dos puntos (gran círculo)."
  def haversine_meters(%{lat: lat1, lng: lng1}, %{lat: lat2, lng: lng2}) do
    dlat = deg2rad(lat2 - lat1)
    dlng = deg2rad(lng2 - lng1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg2rad(lat1)) * :math.cos(deg2rad(lat2)) * :math.sin(dlng / 2) ** 2

    2 * @earth_radius_m * :math.asin(:math.sqrt(a))
  end

  @doc """
  Normaliza un mapa arbitrario a un punto `%{lat: float, lng: float}`.

  Acepta llaves string o atom y los alias `latitude`, `lon`, `longitude`.
  Conserva `id`, `name` y `metadata`. Devuelve `:error` si las coordenadas
  faltan o están fuera de rango.
  """
  def normalize_point(map) when is_map(map) do
    m = Map.new(map, fn {k, v} -> {to_string(k), v} end)
    lat = m["lat"] || m["latitude"]
    lng = m["lng"] || m["lon"] || m["longitude"]

    if valid_lat?(lat) and valid_lng?(lng) do
      extras =
        m
        |> Map.take(["id", "name", "metadata"])
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

      {:ok, Map.merge(extras, %{lat: lat / 1, lng: lng / 1})}
    else
      :error
    end
  end

  def normalize_point(_), do: :error

  @doc "Versión que lanza para datos ya validados (p. ej. leídos de la BD)."
  def normalize_point!(map) do
    {:ok, point} = normalize_point(map)
    point
  end

  defp valid_lat?(lat), do: is_number(lat) and lat >= -90 and lat <= 90
  defp valid_lng?(lng), do: is_number(lng) and lng >= -180 and lng <= 180

  defp deg2rad(deg), do: deg * :math.pi() / 180
end
