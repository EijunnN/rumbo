defmodule Rumbo.Tracking.PartitionManager do
  @moduledoc """
  Mantiene las particiones mensuales de `positions` por delante del reloj:
  al arrancar y cada 12 horas crea (si faltan) las particiones del mes actual
  y los dos siguientes.

  Si la creación falla (p. ej. la partición DEFAULT ya contiene filas de ese
  rango), se loggea y se sigue: los datos siguen aterrizando en DEFAULT, solo
  se pierde el beneficio de pruning para ese mes.

  Deshabilitado en tests vía `config :rumbo, start_partition_manager: false`.
  """

  use GenServer

  require Logger

  alias Rumbo.Repo

  @check_every :timer.hours(12)
  @months_ahead 2

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :ensure}}
  end

  @impl true
  def handle_continue(:ensure, state) do
    ensure_partitions()
    Process.send_after(self(), :ensure, @check_every)
    {:noreply, state}
  end

  @impl true
  def handle_info(:ensure, state) do
    ensure_partitions()
    Process.send_after(self(), :ensure, @check_every)
    {:noreply, state}
  end

  @doc "Crea las particiones del mes actual y los @months_ahead siguientes."
  def ensure_partitions do
    for offset <- 0..@months_ahead do
      first = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: offset)
      next = Date.shift(first, month: 1)
      name = "positions_y#{first.year}m#{String.pad_leading(to_string(first.month), 2, "0")}"

      sql =
        "CREATE TABLE IF NOT EXISTS #{name} PARTITION OF positions " <>
          "FOR VALUES FROM ('#{Date.to_iso8601(first)}') TO ('#{Date.to_iso8601(next)}')"

      case Repo.query(sql) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          Logger.warning("rumbo: no se pudo crear la partición #{name}: #{inspect(error)}")
      end
    end

    :ok
  end
end
