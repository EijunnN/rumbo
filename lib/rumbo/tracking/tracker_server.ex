defmodule Rumbo.Tracking.TrackerServer do
  @moduledoc """
  Estado caliente de un tracker activo: última posición, velocidad suavizada,
  trip activo y throttling de ETA. Hay un proceso por `{project_id, key}`,
  registrado en `Rumbo.TrackerRegistry` y arrancado bajo demanda.

  Responsabilidades:

    * difundir cada posición nueva por PubSub (topic de tracker y de trip)
    * detectar transiciones online/offline y difundirlas como evento `status`
    * delegar la persistencia al `PositionWriter` (lotes globales, nunca
      bloquea el camino caliente)
    * recalcular el ETA del trip activo con throttle (tiempo o distancia),
      en un Task acotado por `Rumbo.Eta.Limiter`
    * contar espectadores (presencia en los topics de watchers del tracker y
      de su trip) y difundir el evento `watchers` cuando cambia — la señal
      para que el dispositivo module su cadencia de GPS

  En clúster, el server de cada tracker vive solo en su nodo dueño
  (`Rumbo.Cluster.owner_node/1`); `ingest/3` reenvía al dueño de forma
  transparente. El proceso se detiene solo tras 30 minutos sin actividad.
  """

  use GenServer, restart: :transient

  require Logger

  alias Rumbo.{Cluster, Eta, Geo, Topics, Trips}
  alias Rumbo.Eta.Limiter
  alias Rumbo.Tracking
  alias Rumbo.Tracking.{Position, PositionWriter}

  @speed_window 6
  @tick_every :timer.seconds(15)
  @idle_stop_after_ms :timer.minutes(30)

  ## API

  def start_link({project, tracker}) do
    GenServer.start_link(__MODULE__, {project, tracker}, name: via(project.id, tracker.key))
  end

  def via(project_id, tracker_key) do
    {:via, Registry, {Rumbo.TrackerRegistry, {project_id, tracker_key}}}
  end

  @doc """
  Entrega un lote de posiciones ya validadas (mapas atom-keyed). Si el nodo
  actual no es el dueño del tracker, reenvía al dueño.
  """
  def ingest(project, tracker, positions) when is_list(positions) do
    case Cluster.owner_node({project.id, tracker.key}) do
      owner when owner == node() -> ingest_local(project, tracker, positions)
      owner -> :erpc.cast(owner, __MODULE__, :ingest_local, [project, tracker, positions])
    end

    :ok
  end

  @doc false
  def ingest_local(project, tracker, positions) do
    {:ok, pid} = ensure_started(project, tracker)
    GenServer.cast(pid, {:ingest, positions})
  end

  @doc "Recarga proyecto y trip activo (tras crear/actualizar un trip)."
  def refresh(project_id, tracker_key) do
    case Cluster.owner_node({project_id, tracker_key}) do
      owner when owner == node() -> refresh_local(project_id, tracker_key)
      owner -> :erpc.cast(owner, __MODULE__, :refresh_local, [project_id, tracker_key])
    end

    :ok
  end

  @doc false
  def refresh_local(project_id, tracker_key) do
    case Registry.lookup(Rumbo.TrackerRegistry, {project_id, tracker_key}) do
      [{pid, _}] -> GenServer.cast(pid, :refresh)
      [] -> :ok
    end
  end

  @doc """
  Barrera síncrona: garantiza que los casts previos fueron procesados.
  Usada por `Tracking.flush/2` (tests, shutdown graceful).
  """
  def sync(project_id, tracker_key) do
    case Registry.lookup(Rumbo.TrackerRegistry, {project_id, tracker_key}) do
      [{pid, _}] -> GenServer.call(pid, :sync)
      [] -> :ok
    end
  end

  @doc """
  Garantiza que el server del tracker esté vivo en su nodo dueño. Lo usa el
  join de un publisher: sin server no habría quién difunda `watchers`.
  """
  def ensure(project, tracker) do
    case Cluster.owner_node({project.id, tracker.key}) do
      owner when owner == node() -> ensure_local(project, tracker)
      owner -> :erpc.cast(owner, __MODULE__, :ensure_local, [project, tracker])
    end

    :ok
  end

  @doc false
  def ensure_local(project, tracker) do
    {:ok, _pid} = ensure_started(project, tracker)
    :ok
  end

  @doc "Espectadores actuales del tracker (0 si el server no está vivo)."
  def watchers(project_id, tracker_key) do
    case Cluster.owner_node({project_id, tracker_key}) do
      owner when owner == node() ->
        watchers_local(project_id, tracker_key)

      owner ->
        try do
          :erpc.call(owner, __MODULE__, :watchers_local, [project_id, tracker_key], 1_000)
        catch
          _, _ -> 0
        end
    end
  end

  @doc false
  def watchers_local(project_id, tracker_key) do
    case Registry.lookup(Rumbo.TrackerRegistry, {project_id, tracker_key}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :watchers, 1_000)
        catch
          :exit, _ -> 0
        end

      [] ->
        0
    end
  end

  defp ensure_started(project, tracker) do
    spec = {__MODULE__, {project, tracker}}

    case DynamicSupervisor.start_child(Rumbo.TrackerSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  ## Callbacks

  @impl true
  def init({project, tracker}) do
    trip = Trips.get_active_trip(project.id, tracker.id)

    Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.tracker_watchers(project.id, tracker.key))

    if trip do
      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.trip_watchers(project.id, trip.id))
    end

    state = %{
      project: project,
      tracker: tracker,
      last_position: restore_position(tracker.last_position),
      last_seen_at: tracker.last_seen_at,
      last_activity_at: System.monotonic_time(:millisecond),
      online: false,
      speeds: [],
      trip: trip,
      eta_task_ref: nil,
      last_eta_at: nil,
      last_eta_point: nil,
      watchers: count_watchers(project.id, tracker.key, trip)
    }

    Process.send_after(self(), :tick, @tick_every)
    {:ok, state}
  end

  @impl true
  def handle_cast({:ingest, positions}, state) do
    state = %{
      state
      | last_activity_at: System.monotonic_time(:millisecond),
        last_seen_at: DateTime.utc_now()
    }

    state = maybe_broadcast_online(state)

    sorted = Enum.sort_by(positions, & &1.recorded_at, DateTime)
    latest = List.last(sorted)

    state =
      if newer?(state, latest) do
        state
        |> apply_latest(latest)
        |> broadcast_position(latest)
        |> maybe_request_eta()
      else
        # Lote enteramente retroactivo (cola offline): se persiste pero no
        # mueve el estado vivo ni el ETA.
        state
      end

    persist(state, sorted)
    {:noreply, state}
  end

  def handle_cast(:refresh, state) do
    project = Rumbo.Projects.get_project(state.project.id) || state.project
    trip = Trips.get_active_trip(project.id, state.tracker.id)

    state = resubscribe_trip_watchers(state, trip)
    state = %{state | project: project, trip: trip, last_eta_at: nil, last_eta_point: nil}

    {:noreply, refresh_watchers(state)}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(:watchers, _from, state), do: {:reply, state.watchers, state}

  @impl true
  def handle_info(:tick, state) do
    state = maybe_broadcast_offline(state)
    idle_ms = System.monotonic_time(:millisecond) - state.last_activity_at

    if idle_ms >= @idle_stop_after_ms do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :tick, @tick_every)
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{eta_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | eta_task_ref: nil}

    case result do
      {:ok, route} ->
        {:noreply, apply_eta_result(state, route)}

      {:error, reason} ->
        Logger.warning("rumbo: ETA falló para #{state.tracker.key}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{eta_task_ref: ref} = state) do
    Logger.warning("rumbo: task de ETA cayó para #{state.tracker.key}: #{inspect(reason)}")
    {:noreply, %{state | eta_task_ref: nil}}
  end

  # Alguien entró o salió de los topics de watchers (canal de trip o tracker).
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, state) do
    {:noreply, refresh_watchers(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Estado vivo

  defp newer?(%{last_position: nil}, _latest), do: true

  defp newer?(%{last_position: %{recorded_at: prev}}, %{recorded_at: at}) do
    DateTime.compare(at, prev) == :gt
  end

  defp apply_latest(state, position) do
    speeds =
      if is_number(position.speed) do
        Enum.take([position.speed | state.speeds], @speed_window)
      else
        state.speeds
      end

    %{state | last_position: position, speeds: speeds}
  end

  defp smoothed_speed(%{speeds: []}), do: nil
  defp smoothed_speed(%{speeds: speeds}), do: Enum.sum(speeds) / length(speeds)

  ## Eventos

  defp maybe_broadcast_online(%{online: true} = state), do: state

  defp maybe_broadcast_online(state) do
    broadcast_status(state, "online")
    %{state | online: true}
  end

  defp maybe_broadcast_offline(%{online: false} = state), do: state

  defp maybe_broadcast_offline(state) do
    threshold = Tracking.offline_after_seconds(state.project)

    if DateTime.diff(DateTime.utc_now(), state.last_seen_at) >= threshold do
      broadcast_status(state, "offline")
      %{state | online: false}
    else
      state
    end
  end

  defp broadcast_status(state, status) do
    payload = %{
      tracker: state.tracker.key,
      status: status,
      last_seen_at: state.last_seen_at
    }

    Tracking.broadcast!(tracker_topic(state), "status", payload)

    if state.trip do
      Tracking.broadcast!(trip_topic(state), "tracker_status", payload)
    end
  end

  defp broadcast_position(state, position) do
    payload =
      position
      |> Map.take(Position.ingest_fields())
      |> Map.put(:tracker, state.tracker.key)
      |> Map.put(:trip_id, state.trip && state.trip.id)

    Tracking.broadcast!(tracker_topic(state), "position", payload)

    if state.trip do
      Tracking.broadcast!(trip_topic(state), "position", payload)
    end

    state
  end

  ## Espectadores

  defp count_watchers(project_id, tracker_key, trip) do
    base = Rumbo.Presence.count(Topics.tracker_watchers(project_id, tracker_key))

    on_trip =
      if trip, do: Rumbo.Presence.count(Topics.trip_watchers(project_id, trip.id)), else: 0

    base + on_trip
  end

  defp refresh_watchers(state) do
    count = count_watchers(state.project.id, state.tracker.key, state.trip)

    if count != state.watchers do
      Tracking.broadcast!(tracker_topic(state), "watchers", %{
        tracker: state.tracker.key,
        watchers: count,
        watched: count > 0
      })
    end

    %{state | watchers: count}
  end

  # El trip activo cambió: mover la suscripción de presencia al trip nuevo.
  defp resubscribe_trip_watchers(state, new_trip) do
    old_id = state.trip && state.trip.id
    new_id = new_trip && new_trip.id

    if old_id != new_id do
      if old_id do
        Phoenix.PubSub.unsubscribe(Rumbo.PubSub, Topics.trip_watchers(state.project.id, old_id))
      end

      if new_id do
        Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.trip_watchers(state.project.id, new_id))
      end
    end

    state
  end

  ## ETA

  defp maybe_request_eta(%{trip: nil} = state), do: state
  defp maybe_request_eta(%{eta_task_ref: ref} = state) when is_reference(ref), do: state

  defp maybe_request_eta(state) do
    settings = Eta.settings(state.project)
    current = %{lat: state.last_position.lat, lng: state.last_position.lng}

    with true <- eta_due?(state, settings, current),
         :ok <- Limiter.acquire() do
      project = state.project
      points = Trips.route_points(state.trip)
      speed = smoothed_speed(state)

      task =
        Task.Supervisor.async_nolink(Rumbo.TaskSupervisor, fn ->
          try do
            Eta.calculate(project, current, points, speed_mps: speed)
          after
            Limiter.release()
          end
        end)

      # last_eta_at se marca al solicitar (no al completar) para que el
      # throttle aplique aunque el cálculo falle o tarde.
      %{state | eta_task_ref: task.ref, last_eta_at: DateTime.utc_now(), last_eta_point: current}
    else
      # :busy (limiter lleno) o throttle vigente: reintenta al próximo ping.
      _ -> state
    end
  end

  defp eta_due?(%{last_eta_at: nil}, _settings, _current), do: true

  defp eta_due?(state, settings, current) do
    DateTime.diff(DateTime.utc_now(), state.last_eta_at) >= settings.throttle_seconds or
      Geo.haversine_meters(state.last_eta_point, current) >= settings.throttle_meters
  end

  defp apply_eta_result(%{trip: nil} = state, _route), do: state

  defp apply_eta_result(state, route) do
    now = DateTime.utc_now()
    points = Trips.route_points(state.trip)

    {legs, _total} =
      route.legs
      |> Enum.zip(points)
      |> Enum.map_reduce(0.0, fn {leg, point}, elapsed ->
        total = elapsed + leg.duration_seconds

        leg_payload =
          point
          |> Map.take([:id, :name, :metadata])
          |> Map.merge(%{
            lat: point.lat,
            lng: point.lng,
            distance_meters: round(leg.distance_meters),
            duration_seconds: round(leg.duration_seconds),
            eta_at: DateTime.add(now, round(total), :second)
          })

        {leg_payload, total}
      end)

    payload =
      %{
        trip_id: state.trip.id,
        tracker: state.tracker.key,
        engine: route.engine,
        distance_meters: round(route.distance_meters),
        duration_seconds: round(route.duration_seconds),
        eta_at: DateTime.add(now, round(route.duration_seconds), :second),
        calculated_at: now,
        legs: legs
      }
      |> maybe_mark_degraded(route)

    Tracking.broadcast!(trip_topic(state), "eta", payload)
    trip = Trips.store_eta(state.trip, payload)
    %{state | trip: trip}
  end

  defp maybe_mark_degraded(payload, %{degraded: true} = route) do
    Map.merge(payload, %{degraded: true, degraded_reason: route.degraded_reason})
  end

  defp maybe_mark_degraded(payload, _route), do: payload

  ## Persistencia (delegada al writer global)

  defp persist(state, positions) do
    now = DateTime.utc_now()

    rows =
      Enum.map(positions, fn position ->
        position
        |> Map.take(Position.ingest_fields())
        |> Map.merge(%{
          project_id: state.project.id,
          tracker_id: state.tracker.id,
          trip_id: state.trip && state.trip.id,
          inserted_at: now
        })
      end)

    snapshot = {snapshot(state.last_position), state.last_seen_at}
    PositionWriter.push(state.tracker.id, rows, snapshot)
  end

  ## Snapshot jsonb <-> estado

  defp snapshot(nil), do: nil

  defp snapshot(position) do
    position
    |> Map.take(Position.ingest_fields())
    |> Map.update!(:recorded_at, &DateTime.to_iso8601/1)
  end

  defp restore_position(nil), do: nil

  defp restore_position(stored) do
    with {:ok, position} <- Position.parse(stored) do
      position
    else
      _ -> nil
    end
  end

  defp tracker_topic(state), do: Topics.tracker(state.project.id, state.tracker.key)
  defp trip_topic(state), do: Topics.trip(state.project.id, state.trip.id)
end
