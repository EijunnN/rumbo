defmodule Rumbo.Cluster do
  @moduledoc """
  Asignación de trackers a nodos del clúster.

  El estado caliente de un tracker (TrackerServer) debe vivir en exactamente
  un nodo. Con `Registry` local eso no está garantizado al escalar
  horizontalmente: dos nodos que reciben ingest del mismo tracker arrancarían
  dos servers. Este módulo define un dueño determinista por hash sobre la
  lista ordenada de nodos visibles; el ingest se reenvía al dueño con
  `:erpc.cast` (ver `TrackerServer.ingest/3`).

  Con un solo nodo el dueño siempre es local: cero overhead.

  Cuando la topología cambia, el hash reasigna trackers; el server del nodo
  anterior deja de recibir tráfico y muere solo por timeout de inactividad.
  Durante el rebalanceo breve pueden coexistir dos servers para un tracker:
  es benigno (las posiciones son idempotentes por recorded_at y el ETA
  duplicado converge).
  """

  def owner_node(key) do
    case Node.list() do
      [] -> node()
      others -> owner_node(key, [node() | others])
    end
  end

  @doc "Versión determinista sobre una lista explícita de nodos (testeable)."
  def owner_node(key, nodes) when is_list(nodes) and nodes != [] do
    sorted = Enum.sort(nodes)
    Enum.at(sorted, :erlang.phash2(key, length(sorted)))
  end

  def local?(key), do: owner_node(key) == node()
end
