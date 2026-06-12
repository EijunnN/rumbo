defmodule Rumbo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :rumbo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Crea un proyecto con su API key desde un release (donde no existe Mix):

      bin/rumbo eval 'Rumbo.Release.gen_project("Mi App")'
  """
  def gen_project(name, label \\ "default") do
    load_app()

    {:ok, _} = Application.ensure_all_started(@app)

    case Rumbo.Projects.create_project_with_key(%{name: name}, label) do
      {:ok, %{project: project, raw_key: raw_key}} ->
        IO.puts("""

        Proyecto creado
          id:   #{project.id}
          name: #{project.name}
          slug: #{project.slug}

        API key (guárdala ahora; no se puede volver a ver):

          #{raw_key}
        """)

      {:error, changeset} ->
        IO.puts("Error: #{inspect(changeset.errors)}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
