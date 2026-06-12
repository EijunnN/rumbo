defmodule Rumbo.Projects.ApiKey do
  @moduledoc """
  API key de servidor (formato `rk_<random>`). Solo se almacena el hash SHA-256;
  la key en claro se muestra una única vez al crearla. `prefix` guarda los
  primeros caracteres para poder identificarla en listados.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :label, :string
    field :prefix, :string
    field :key_hash, :binary
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :project, Rumbo.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end
end
