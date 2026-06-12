defmodule Rumbo.Tracking.Position do
  @moduledoc """
  Un ping GPS. La tabla usa id bigserial (volumen alto) y un índice único
  `(tracker_id, recorded_at)` que hace idempotentes los reintentos de colas
  offline.

  `parse/1` es el único punto de entrada de datos crudos: normaliza alias de
  llaves comunes (`lon`, `latitude`, `bearing`, `batteryLevel`, `timestamp`
  unix en segundos o milisegundos) y valida rangos.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id
  schema "positions" do
    field :lat, :float
    field :lng, :float
    field :speed, :float
    field :heading, :float
    field :accuracy, :float
    field :altitude, :float
    field :battery, :float
    field :metadata, :map
    field :recorded_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :project, Rumbo.Projects.Project
    belongs_to :tracker, Rumbo.Tracking.Tracker
    belongs_to :trip, Rumbo.Trips.Trip
  end

  @ingest_fields [
    :lat,
    :lng,
    :speed,
    :heading,
    :accuracy,
    :altitude,
    :battery,
    :metadata,
    :recorded_at
  ]

  @doc """
  Valida un ping crudo y lo devuelve como mapa atom-keyed listo para el
  TrackerServer. `{:error, changeset}` si es inválido.
  """
  def parse(raw) when is_map(raw) do
    %__MODULE__{}
    |> cast(normalize(raw), @ingest_fields)
    |> validate_required([:lat, :lng])
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_number(:battery, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> default_recorded_at()
    |> apply_action(:insert)
    |> case do
      {:ok, struct} -> {:ok, Map.take(struct, @ingest_fields)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def parse(_), do: {:error, change(%__MODULE__{}) |> add_error(:base, "must be a map")}

  @doc "Campos que viajan en payloads de eventos y filas de insert_all."
  def ingest_fields, do: @ingest_fields

  defp normalize(raw) do
    m = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    %{
      "lat" => m["lat"] || m["latitude"],
      "lng" => m["lng"] || m["lon"] || m["longitude"],
      "speed" => m["speed"],
      "heading" => m["heading"] || m["bearing"],
      "accuracy" => m["accuracy"],
      "altitude" => m["altitude"],
      "battery" => m["battery"] || m["battery_level"] || m["batteryLevel"],
      "metadata" => m["metadata"],
      "recorded_at" => normalize_timestamp(m["recorded_at"] || m["timestamp"])
    }
  end

  # Acepta ISO8601 (lo castea Ecto), unix en segundos o en milisegundos.
  defp normalize_timestamp(ts) when is_integer(ts) do
    unit = if ts > 99_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(ts, unit) do
      {:ok, dt} -> dt
      _ -> ts
    end
  end

  defp normalize_timestamp(ts), do: ts

  defp default_recorded_at(changeset) do
    case get_field(changeset, :recorded_at) do
      nil -> put_change(changeset, :recorded_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
