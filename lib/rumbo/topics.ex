defmodule Rumbo.Topics do
  @moduledoc """
  Topics internos de PubSub, siempre acotados por proyecto.

  Los topics de los canales que ve el cliente (`tracker:driver_42`) no incluyen
  el project_id, así que nunca se publica directamente sobre ellos: cada canal
  se suscribe en `join/3` al topic interno correspondiente. Esto evita
  cross-talk entre proyectos que usen las mismas keys de tracker.
  """

  def tracker(project_id, tracker_key), do: "proj:#{project_id}:tracker:#{tracker_key}"

  def trip(project_id, trip_id), do: "proj:#{project_id}:trip:#{trip_id}"
end
