defmodule Rumbo.Tracking.Policy do
  @moduledoc """
  Política de tracking que el servidor sugiere a los dispositivos.

  El consumo de batería lo ejecuta el móvil (GPS, radio), pero la política la
  define el proyecto aquí — así el operador ajusta la agresividad del tracking
  de toda su flota sin re-deployar la app. Se entrega en el snapshot del join
  de `tracker:<key>` y en cada respuesta 202 de ingesta.

  Override por proyecto en settings:

      {"tracking": {"policy": {"ping_interval_s": 60, "min_displacement_m": 50}}}

  Campos (sugerencias para el dispositivo, no se imponen del lado servidor):

    * `ping_interval_s` — cadencia base de muestreo GPS
    * `watched_ping_interval_s` — cadencia cuando alguien está mirando el
      trip/tracker (ver el evento `watchers`)
    * `min_displacement_m` — distance filter: sin movimiento, sin muestras
    * `batch_max_wait_s` — cuánto acumular antes de enviar el lote (menos
      despertares de radio)
    * `low_battery_pct` / `low_battery_interval_s` — debajo de ese nivel de
      batería, bajar a esta cadencia
  """

  alias Rumbo.Projects.Project

  @defaults %{
    ping_interval_s: 30,
    watched_ping_interval_s: 10,
    min_displacement_m: 25,
    batch_max_wait_s: 60,
    low_battery_pct: 20,
    low_battery_interval_s: 120
  }

  def for_project(%Project{settings: settings}) do
    overrides =
      case settings do
        %{"tracking" => %{"policy" => %{} = policy}} -> policy
        _ -> %{}
      end

    Map.new(@defaults, fn {key, default} ->
      {key, Map.get(overrides, to_string(key), default)}
    end)
  end
end
