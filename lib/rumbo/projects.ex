defmodule Rumbo.Projects do
  @moduledoc """
  Contexto de tenants: proyectos y sus API keys.
  """

  import Ecto.Query

  alias Rumbo.Projects.{ApiKey, Project}
  alias Rumbo.Repo

  ## Proyectos

  def get_project(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Project, uuid)
      :error -> nil
    end
  end

  def get_project_by_slug(slug), do: Repo.get_by(Project, slug: slug)

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Crea un proyecto junto con su primera API key. Devuelve la key en claro,
  que no vuelve a ser recuperable.
  """
  def create_project_with_key(attrs, label \\ "default") do
    with {:ok, project} <- create_project(attrs),
         {:ok, api_key, raw_key} <- create_api_key(project, label) do
      {:ok, %{project: project, api_key: api_key, raw_key: raw_key}}
    end
  end

  ## API keys

  def create_api_key(%Project{} = project, label \\ "default") do
    raw = "rk_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    %ApiKey{
      project_id: project.id,
      label: label,
      prefix: String.slice(raw, 0, 10),
      key_hash: hash(raw)
    }
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {:ok, api_key, raw}
      error -> error
    end
  end

  @doc "Autentica una API key en claro. Devuelve el proyecto dueño."
  def authenticate_api_key("rk_" <> _ = raw) do
    query =
      from k in ApiKey,
        where: k.key_hash == ^hash(raw) and is_nil(k.revoked_at),
        preload: :project

    case Repo.one(query) do
      nil ->
        {:error, :unauthorized}

      api_key ->
        touch_last_used(api_key)
        {:ok, api_key.project}
    end
  end

  def authenticate_api_key(_), do: {:error, :unauthorized}

  def revoke_api_key(%Project{id: project_id}, api_key_id) do
    case Repo.get_by(ApiKey, id: api_key_id, project_id: project_id) do
      nil ->
        {:error, :not_found}

      api_key ->
        api_key
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  # Actualiza last_used_at como máximo una vez por minuto para no convertir
  # cada request autenticado en un UPDATE.
  defp touch_last_used(%ApiKey{} = api_key) do
    stale? =
      api_key.last_used_at == nil or
        DateTime.diff(DateTime.utc_now(), api_key.last_used_at) > 60

    if stale? do
      from(k in ApiKey, where: k.id == ^api_key.id)
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now()])
    end

    :ok
  end
end
