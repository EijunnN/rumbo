defmodule Rumbo.Eta.Engine do
  @moduledoc """
  Contrato de los motores de ETA.

  Un motor recibe la posición actual y los puntos restantes de la ruta
  (waypoints + destino) y devuelve distancia/duración totales más una pierna
  por punto. `opts` incluye `:settings` (mapa de `Rumbo.Eta.settings/1`) y
  `:speed_mps` (velocidad suavizada actual del tracker, puede ser nil).
  """

  @type point :: %{
          required(:lat) => float(),
          required(:lng) => float(),
          optional(atom()) => any()
        }

  @type leg :: %{
          distance_meters: number(),
          duration_seconds: number()
        }

  @type route :: %{
          distance_meters: number(),
          duration_seconds: number(),
          legs: [leg()]
        }

  @callback route(from :: point(), waypoints :: [point()], opts :: keyword()) ::
              {:ok, route()} | {:error, term()}
end
