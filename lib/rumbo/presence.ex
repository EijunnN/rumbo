defmodule Rumbo.Presence do
  @moduledoc """
  Presencia distribuida de espectadores (watchers).

  Cada canal que "mira" un tracker se registra en un topic de watchers
  (`Rumbo.Topics.tracker_watchers/2` o `trip_watchers/2`). El TrackerServer
  del tracker escucha los `presence_diff` de esos topics y difunde el evento
  `watchers` para que el dispositivo suba la cadencia de GPS solo cuando
  alguien está mirando — la información de ahorro de batería que el móvil no
  puede conocer por sí mismo.

  Al ser Phoenix.Presence (CRDT sobre PubSub), el conteo es correcto aunque
  los canales y el TrackerServer vivan en nodos distintos.
  """

  use Phoenix.Presence, otp_app: :rumbo, pubsub_server: Rumbo.PubSub

  @doc "Total de conexiones presentes en un topic."
  def count(topic) do
    topic
    |> list()
    |> Enum.reduce(0, fn {_key, %{metas: metas}}, acc -> acc + length(metas) end)
  end
end
