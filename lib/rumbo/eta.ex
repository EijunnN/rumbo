defmodule Rumbo.Eta do
  @moduledoc """
  Fachada del cálculo de ETA. Resuelve el motor según la configuración del
  proyecto y aplica los defaults.

  Con motor `osrm`, los fallos pasan por un circuit breaker
  (`Rumbo.Eta.Breaker`) y degradan automáticamente a haversine: el cliente
  sigue recibiendo eventos `eta` (marcados con `degraded: true`) aunque el
  servidor de rutas esté caído.
  """

  require Logger

  alias Rumbo.Eta.{Breaker, Haversine, Osrm}
  alias Rumbo.Projects.Project

  @defaults %{
    engine: "haversine",
    osrm_url: nil,
    profile: "driving",
    circuity: 1.3,
    fallback_speed_kmh: 25.0,
    min_speed_kmh: 5.0,
    throttle_seconds: 30,
    throttle_meters: 150
  }

  @doc "Settings de ETA del proyecto con defaults aplicados (atom-keyed)."
  def settings(%Project{settings: settings}) do
    overrides =
      case settings do
        %{"eta" => %{} = eta} -> eta
        _ -> %{}
      end

    Map.new(@defaults, fn {key, default} ->
      {key, Map.get(overrides, to_string(key), default)}
    end)
  end

  @doc """
  Calcula la ruta desde `from` pasando por `points` (el destino al final).
  Devuelve el resultado del motor con `:engine` incluido.
  """
  def calculate(%Project{} = project, from, points, opts \\ []) do
    config = settings(project)
    opts = Keyword.put(opts, :settings, config)
    do_calculate(config.engine, config, from, points, opts)
  end

  defp do_calculate("osrm", %{osrm_url: nil}, from, points, opts) do
    fallback(from, points, opts, :osrm_url_not_configured)
  end

  defp do_calculate("osrm", config, from, points, opts) do
    if Breaker.available?(config.osrm_url) do
      case Osrm.route(from, points, opts) do
        {:ok, route} ->
          Breaker.record_success(config.osrm_url)
          {:ok, Map.put(route, :engine, "osrm")}

        {:error, reason} ->
          Breaker.record_failure(config.osrm_url)
          Logger.warning("rumbo: OSRM falló (#{inspect(reason)}), degradando a haversine")
          fallback(from, points, opts, reason)
      end
    else
      fallback(from, points, opts, :circuit_open)
    end
  end

  defp do_calculate(_engine, _config, from, points, opts) do
    with {:ok, route} <- Haversine.route(from, points, opts) do
      {:ok, Map.put(route, :engine, "haversine")}
    end
  end

  defp fallback(from, points, opts, reason) do
    with {:ok, route} <- Haversine.route(from, points, opts) do
      {:ok,
       Map.merge(route, %{engine: "haversine", degraded: true, degraded_reason: inspect(reason)})}
    end
  end
end
