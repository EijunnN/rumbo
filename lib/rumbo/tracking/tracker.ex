defmodule Rumbo.Tracking.Tracker do
  @moduledoc """
  Una entidad que se mueve (conductor, vehículo, paquete). Se identifica por
  una `key` externa definida por el consumidor (p. ej. `driver_42`) y se crea
  implícitamente con el primer ping: no requiere registro previo.

  `last_position`/`last_seen_at` son un snapshot desnormalizado que mantiene
  el TrackerServer para responder consultas sin tocar el histórico.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "trackers" do
    field :key, :string
    field :name, :string
    field :metadata, :map, default: %{}
    field :last_position, :map
    field :last_seen_at, :utc_datetime_usec

    belongs_to :project, Rumbo.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tracker, attrs) do
    tracker
    |> cast(attrs, [:name, :metadata])
    |> validate_length(:name, max: 255)
    |> unique_constraint([:project_id, :key])
  end
end
