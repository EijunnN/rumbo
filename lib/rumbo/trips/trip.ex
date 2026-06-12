defmodule Rumbo.Trips.Trip do
  @moduledoc """
  Una sesión de tracking con destino: el contexto contra el que se calcula el
  ETA. `waypoints` son paradas intermedias ordenadas; el consumidor las
  actualiza (PATCH) a medida que se completan y el ETA se recalcula contra las
  restantes.

  Estados: `active` → `completed` | `canceled` (terminales).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Rumbo.Geo

  @statuses ~w(active completed canceled)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trips" do
    field :status, :string, default: "active"
    field :destination, :map
    field :waypoints, {:array, :map}, default: []
    field :metadata, :map, default: %{}
    field :eta, :map
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :project, Rumbo.Projects.Project
    belongs_to :tracker, Rumbo.Tracking.Tracker

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def create_changeset(trip, attrs) do
    trip
    |> cast(attrs, [:destination, :waypoints, :metadata])
    |> validate_required([:destination])
    |> normalize_point_change(:destination)
    |> normalize_waypoints_change()
    |> put_change(:started_at, DateTime.utc_now())
    |> unique_constraint(:tracker_id,
      name: :trips_one_active_per_tracker,
      message: "tracker already has an active trip"
    )
  end

  def update_changeset(trip, attrs) do
    trip
    |> cast(attrs, [:status, :destination, :waypoints, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> normalize_point_change(:destination)
    |> normalize_waypoints_change()
    |> validate_status_transition(trip.status)
    |> maybe_put_ended_at()
  end

  defp validate_status_transition(changeset, current_status) do
    case get_change(changeset, :status) do
      nil ->
        changeset

      _new when current_status != "active" ->
        add_error(changeset, :status, "trip is already #{current_status}")

      _new ->
        changeset
    end
  end

  defp maybe_put_ended_at(changeset) do
    case get_change(changeset, :status) do
      status when status in ["completed", "canceled"] ->
        put_change(changeset, :ended_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end

  defp normalize_point_change(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Geo.normalize_point(value) do
          {:ok, point} -> put_change(changeset, field, point)
          :error -> add_error(changeset, field, "must be a point with numeric lat/lng")
        end
    end
  end

  defp normalize_waypoints_change(changeset) do
    case get_change(changeset, :waypoints) do
      nil ->
        changeset

      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn waypoint, {:ok, acc} ->
          case Geo.normalize_point(waypoint) do
            {:ok, point} -> {:cont, {:ok, [point | acc]}}
            :error -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, points} -> put_change(changeset, :waypoints, Enum.reverse(points))
          :error -> add_error(changeset, :waypoints, "each waypoint must have numeric lat/lng")
        end

      _ ->
        add_error(changeset, :waypoints, "must be a list")
    end
  end
end
