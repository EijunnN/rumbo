defmodule Rumbo.Tracking do
  @moduledoc """
  Contexto de tracking: ingesta de posiciones, trackers y su estado vivo.

  La ingesta valida en el proceso del caller (request/canal) y delega el
  estado caliente al `TrackerServer` del tracker, que difunde por PubSub y
  persiste en lotes.
  """

  import Ecto.Query

  alias Rumbo.Projects.Project
  alias Rumbo.Repo
  alias Rumbo.Tracking.{Position, PositionWriter, Tracker, TrackerServer}

  @tracker_key_format ~r/^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$/
  @max_batch 500
  @default_offline_after 90

  ## Ingesta

  @doc """
  Ingresa un lote de posiciones crudas para `tracker_key`, creando el tracker
  si no existe. Valida todo el lote antes de aceptar nada.
  """
  def ingest(%Project{} = project, tracker_key, raw_positions) when is_list(raw_positions) do
    with :ok <- validate_tracker_key(tracker_key),
         :ok <- validate_batch_size(raw_positions),
         {:ok, positions} <- parse_positions(raw_positions),
         {:ok, tracker} <- get_or_create_tracker(project, tracker_key) do
      TrackerServer.ingest(project, tracker, positions)
      {:ok, %{accepted: length(positions), tracker: tracker.key}}
    end
  end

  def ingest(_project, _key, _other), do: {:error, :no_positions}

  defp validate_batch_size([]), do: {:error, :no_positions}
  defp validate_batch_size(list) when length(list) > @max_batch, do: {:error, :batch_too_large}
  defp validate_batch_size(_), do: :ok

  defp parse_positions(raw_positions) do
    raw_positions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case Position.parse(raw) do
        {:ok, position} -> {:cont, {:ok, [position | acc]}}
        {:error, changeset} -> {:halt, {:error, {:invalid_position, index, changeset}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  ## Trackers

  def validate_tracker_key(key) when is_binary(key) do
    if Regex.match?(@tracker_key_format, key), do: :ok, else: {:error, :invalid_tracker_key}
  end

  def validate_tracker_key(_), do: {:error, :invalid_tracker_key}

  def get_tracker(%Project{id: project_id}, key) do
    Repo.get_by(Tracker, project_id: project_id, key: key)
  end

  def fetch_tracker(project, key) do
    case get_tracker(project, key) do
      nil -> {:error, :not_found}
      tracker -> {:ok, tracker}
    end
  end

  def get_or_create_tracker(%Project{} = project, key) do
    with :ok <- validate_tracker_key(key) do
      case get_tracker(project, key) do
        nil -> insert_tracker(project, key)
        tracker -> {:ok, tracker}
      end
    end
  end

  defp insert_tracker(project, key) do
    %Tracker{project_id: project.id, key: key}
    |> Tracker.changeset(%{})
    |> Repo.insert()
    |> case do
      {:ok, tracker} ->
        {:ok, tracker}

      # Carrera con otro ingest concurrente: el tracker ya existe.
      {:error, %Ecto.Changeset{}} ->
        {:ok, Repo.get_by!(Tracker, project_id: project.id, key: key)}
    end
  end

  @doc "Crea o actualiza name/metadata de un tracker (PUT /v1/trackers/:key)."
  def upsert_tracker(%Project{} = project, key, attrs) do
    with :ok <- validate_tracker_key(key) do
      case get_tracker(project, key) do
        nil ->
          %Tracker{project_id: project.id, key: key}
          |> Tracker.changeset(attrs)
          |> Repo.insert()

        tracker ->
          tracker
          |> Tracker.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  def list_trackers(%Project{id: project_id}) do
    Repo.all(from t in Tracker, where: t.project_id == ^project_id, order_by: t.key)
  end

  ## Historial

  @doc """
  Posiciones históricas de un tracker, más recientes primero.
  Opciones: `:from`, `:to` (DateTime), `:limit` (default 100, máx. 1000).
  """
  def list_positions(%Project{} = project, key, opts \\ []) do
    with {:ok, tracker} <- fetch_tracker(project, key) do
      limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)

      query =
        from p in Position,
          where: p.tracker_id == ^tracker.id,
          order_by: [desc: p.recorded_at],
          limit: ^limit

      query =
        if from_dt = opts[:from], do: where(query, [p], p.recorded_at >= ^from_dt), else: query

      query = if to_dt = opts[:to], do: where(query, [p], p.recorded_at <= ^to_dt), else: query

      {:ok, Repo.all(query)}
    end
  end

  ## Estado vivo

  def offline_after_seconds(%Project{settings: settings}) do
    case get_in(settings, ["tracking", "offline_after_seconds"]) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_offline_after
    end
  end

  def online?(_project, %Tracker{last_seen_at: nil}), do: false

  def online?(project, %Tracker{last_seen_at: last_seen_at}) do
    DateTime.diff(DateTime.utc_now(), last_seen_at) < offline_after_seconds(project)
  end

  @doc """
  Fuerza la escritura de todo lo pendiente de un tracker: barrera síncrona
  sobre su TrackerServer y flush de los writers. Para tests y shutdown
  graceful; en operación normal el writer ya escribe cada segundo.
  """
  def flush(%Project{id: project_id}, tracker_key) do
    :ok = TrackerServer.sync(project_id, tracker_key)
    PositionWriter.flush_all()
  end

  @doc """
  Difunde un evento como `Phoenix.Socket.Broadcast` para que los canales lo
  reenvíen tal cual desde `handle_info/2`.
  """
  def broadcast!(topic, event, payload) do
    Phoenix.PubSub.broadcast!(Rumbo.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: event,
      payload: payload
    })
  end
end
