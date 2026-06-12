defmodule Rumbo.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string
      add :prefix, :string, null: false
      add :key_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:project_id])

    create table(:trackers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :name, :string
      add :metadata, :map, null: false, default: %{}
      add :last_position, :map
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trackers, [:project_id, :key])

    create table(:trips, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tracker_id, references(:trackers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "active"
      add :destination, :map, null: false
      add :waypoints, {:array, :map}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :eta, :map
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:trips, [:project_id])
    create index(:trips, [:tracker_id])

    # Un solo trip activo por tracker: el ETA siempre tiene un destino inequívoco
    create unique_index(:trips, [:tracker_id],
             where: "status = 'active'",
             name: :trips_one_active_per_tracker
           )

    create table(:positions) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tracker_id, references(:trackers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :trip_id, references(:trips, type: :binary_id, on_delete: :nilify_all)
      add :lat, :float, null: false
      add :lng, :float, null: false
      add :speed, :float
      add :heading, :float
      add :accuracy, :float
      add :altitude, :float
      add :battery, :float
      add :metadata, :map
      add :recorded_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Dedupe natural para reintentos de colas offline (insert_all on_conflict: :nothing)
    create unique_index(:positions, [:tracker_id, :recorded_at])
    create index(:positions, [:project_id])
    create index(:positions, [:trip_id])
  end
end
