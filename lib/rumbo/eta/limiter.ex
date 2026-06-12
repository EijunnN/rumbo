defmodule Rumbo.Eta.Limiter do
  @moduledoc """
  Límite de cálculos de ETA concurrentes por nodo.

  Sin esto, un pico de pings con muchos trips activos puede lanzar miles de
  Tasks contra OSRM a la vez. El limiter es un contador lock-free
  (`:atomics`): si no hay slot, el TrackerServer simplemente no marca el
  throttle y reintenta con el siguiente ping — el ETA se degrada en latencia,
  nunca en avalancha.

  Config: `config :rumbo, eta_max_concurrency: 200`
  """

  @counter_key {__MODULE__, :counter}

  @doc "Inicializa el contador. Llamar una vez en Application.start/2."
  def setup! do
    :persistent_term.put(@counter_key, :atomics.new(1, signed: true))
    :ok
  end

  @spec acquire() :: :ok | :busy
  def acquire do
    ref = :persistent_term.get(@counter_key)

    if :atomics.add_get(ref, 1, 1) > max_concurrency() do
      :atomics.sub(ref, 1, 1)
      :busy
    else
      :ok
    end
  end

  def release do
    :atomics.sub(:persistent_term.get(@counter_key), 1, 1)
    :ok
  end

  def in_flight, do: :atomics.get(:persistent_term.get(@counter_key), 1)

  defp max_concurrency, do: Application.get_env(:rumbo, :eta_max_concurrency, 200)
end
