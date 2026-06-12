# Crea un proyecto "demo" para desarrollo, con su API key impresa en consola.
# Corre con `mix ecto.setup` o `mix run priv/repo/seeds.exs`.

case Rumbo.Projects.get_project_by_slug("demo") do
  nil ->
    {:ok, %{project: project, raw_key: raw_key}} =
      Rumbo.Projects.create_project_with_key(%{name: "Demo", slug: "demo"})

    IO.puts("""

    Proyecto demo creado (id: #{project.id})
    API key de desarrollo (guárdala; no se vuelve a mostrar):

      #{raw_key}
    """)

  _project ->
    IO.puts("El proyecto demo ya existe. Genera otra key con: mix rumbo.gen.project")
end
