defmodule Rumbo.Eta.Breaker do
  @moduledoc """
  Circuit breaker por servidor OSRM.

  Tras #{5} fallos consecutivos contra una URL, el circuito se abre por
  #{30} segundos: durante ese tiempo `Rumbo.Eta` ni siquiera intenta el
  request y cae directo al fallback haversine. Evita que un OSRM caído
  acumule miles de tasks esperando timeout de 5 s.

  Estado en ETS pública (lecturas lock-free desde cualquier proceso); este
  GenServer solo es el dueño de la tabla.
  """

  use GenServer

  @table :rumbo_eta_breaker
  @failure_threshold 5
  @cooldown_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc "¿Se puede intentar un request contra esta URL?"
  def available?(url) do
    case :ets.lookup(@table, {url, :open}) do
      [{_, opened_until}] -> System.monotonic_time(:millisecond) >= opened_until
      [] -> true
    end
  end

  def record_failure(url) do
    failures = :ets.update_counter(@table, {url, :failures}, 1, {{url, :failures}, 0})

    if failures >= @failure_threshold do
      opened_until = System.monotonic_time(:millisecond) + @cooldown_ms
      :ets.insert(@table, {{url, :open}, opened_until})
      :ets.delete(@table, {url, :failures})
    end

    :ok
  end

  def record_success(url) do
    :ets.delete(@table, {url, :failures})
    :ets.delete(@table, {url, :open})
    :ok
  end
end
