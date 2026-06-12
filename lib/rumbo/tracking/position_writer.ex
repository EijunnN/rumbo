defmodule Rumbo.Tracking.PositionWriter do
  @moduledoc """
  Writer agregador de posiciones: el cuello de botella de Postgres a escala.

  Sin esto, cada TrackerServer insertaría sus propios lotes de 1-2 filas
  (un millón de trackers con ping cada 30 s ≈ 33k INSERTs/s pequeños). Este
  writer agrupa filas de TODOS los trackers y las escribe en lotes grandes:

    * N shards bajo un `PartitionSupervisor` (uno por scheduler), ruteados
      por `tracker_id` — paraleliza sin perder el orden por tracker
    * flush cada segundo o al juntar #{2_000} filas, en chunks de 1.000 con
      `insert_all ... ON CONFLICT DO NOTHING` (dedupe de reintentos offline)
    * los snapshots de trackers (última posición/last_seen) se colapsan por
      tracker (último gana) y se aplican en un solo UPDATE masivo via unnest
    * backpressure: si Postgres no responde, el buffer retiene hasta
      #{50_000} filas por shard y después descarta las más antiguas — el
      estado vivo (PubSub, snapshots en memoria) nunca se bloquea
  """

  use GenServer

  require Logger

  alias Rumbo.Repo
  alias Rumbo.Tracking.Position

  @flush_every 1_000
  @flush_at_rows 2_000
  @insert_chunk 1_000
  @max_buffered_rows 50_000

  ## API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Encola filas de posiciones y el snapshot vivo del tracker. Cast: el camino
  caliente del ingest nunca espera a Postgres.
  """
  def push(tracker_id, rows, snapshot) do
    GenServer.cast(via(tracker_id), {:push, rows, tracker_id, snapshot})
  end

  @doc "Vacía todos los shards de forma síncrona (tests, shutdown graceful)."
  def flush_all do
    Rumbo.PositionWriters
    |> PartitionSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} -> GenServer.call(pid, :flush) end)
  end

  defp via(key), do: {:via, PartitionSupervisor, {Rumbo.PositionWriters, key}}

  ## Callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    schedule_flush()
    {:ok, %{batches: [], count: 0, snapshots: %{}}}
  end

  @impl true
  def handle_cast({:push, rows, tracker_id, snapshot}, state) do
    state = %{
      state
      | batches: [rows | state.batches],
        count: state.count + length(rows),
        snapshots: Map.put(state.snapshots, tracker_id, snapshot)
    }

    if state.count >= @flush_at_rows do
      {:noreply, do_flush(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  @impl true
  def handle_info(:flush_tick, state) do
    schedule_flush()
    {:noreply, do_flush(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  ## Flush

  defp schedule_flush, do: Process.send_after(self(), :flush_tick, @flush_every)

  defp do_flush(%{count: 0, snapshots: snapshots} = state) when map_size(snapshots) == 0,
    do: state

  defp do_flush(state) do
    rows = state.batches |> Enum.reverse() |> List.flatten()

    try do
      rows
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.each(fn chunk ->
        Repo.insert_all(Position, chunk,
          on_conflict: :nothing,
          conflict_target: [:tracker_id, :recorded_at]
        )
      end)

      apply_snapshots(state.snapshots)
      %{state | batches: [], count: 0, snapshots: %{}}
    rescue
      error in DBConnection.OwnershipError ->
        # Solo ocurre en tests cuando el sandbox ya cerró: descartar sin ruido.
        Logger.debug("rumbo: flush sin owner de sandbox: #{Exception.message(error)}")
        %{state | batches: [], count: 0, snapshots: %{}}

      error ->
        Logger.error("rumbo: flush de posiciones falló, reteniendo buffer: #{inspect(error)}")
        retain_with_backpressure(state)
    end
  end

  # Postgres caído: retener lo buffereado para reintentar en el próximo tick,
  # descartando lo más antiguo si se supera el límite.
  defp retain_with_backpressure(%{count: count} = state) when count <= @max_buffered_rows,
    do: state

  defp retain_with_backpressure(state) do
    rows = state.batches |> Enum.reverse() |> List.flatten()
    dropped = length(rows) - @max_buffered_rows
    kept = Enum.drop(rows, dropped)

    Logger.error("rumbo: buffer de posiciones al límite, descartando #{dropped} filas antiguas")

    %{state | batches: [kept], count: length(kept)}
  end

  # Un solo UPDATE para todos los snapshots del lote:
  #   UPDATE trackers SET ... FROM unnest($uuids, $jsons, $timestamps)
  defp apply_snapshots(snapshots) when map_size(snapshots) == 0, do: :ok

  defp apply_snapshots(snapshots) do
    {ids, positions_json, seen_ats} =
      snapshots
      |> Enum.map(fn {tracker_id, {last_position, last_seen_at}} ->
        {Ecto.UUID.dump!(tracker_id), Jason.encode!(last_position), last_seen_at}
      end)
      |> Enum.reduce({[], [], []}, fn {id, json, at}, {ids, jsons, ats} ->
        {[id | ids], [json | jsons], [at | ats]}
      end)

    Repo.query!(
      """
      UPDATE trackers AS t
      SET last_position = v.last_position::jsonb,
          last_seen_at = v.last_seen_at,
          updated_at = now()
      FROM (
        SELECT unnest($1::uuid[]) AS id,
               unnest($2::text[]) AS last_position,
               unnest($3::timestamptz[]) AS last_seen_at
      ) AS v
      WHERE t.id = v.id
      """,
      [ids, positions_json, seen_ats]
    )

    :ok
  end
end
