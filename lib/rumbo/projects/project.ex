defmodule Rumbo.Projects.Project do
  @moduledoc """
  Un tenant de la API. Cada aplicación consumidora (BetterRoute, proyectos
  futuros) es un proyecto con sus propias API keys, trackers y trips.

  `settings` es JSON libre con secciones conocidas:

      {
        "eta": {
          "engine": "haversine" | "osrm",
          "osrm_url": "http://localhost:5000",
          "profile": "driving",
          "circuity": 1.3,
          "fallback_speed_kmh": 25,
          "min_speed_kmh": 5,
          "throttle_seconds": 30,
          "throttle_meters": 150
        },
        "tracking": {"offline_after_seconds": 90}
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field :name, :string
    field :slug, :string
    field :settings, :map, default: %{}

    has_many :api_keys, Rumbo.Projects.ApiKey

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :settings])
    |> validate_required([:name])
    |> put_slug()
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9\-]*$/)
    |> unique_constraint(:slug)
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil -> put_change(changeset, :slug, slugify(get_field(changeset, :name) || ""))
      _ -> changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
