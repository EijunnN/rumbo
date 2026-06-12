defmodule Mix.Tasks.Rumbo.Gen.Project do
  @shortdoc "Crea un proyecto (tenant) con su API key"

  @moduledoc """
  Crea un proyecto y su primera API key. La key se muestra una sola vez.

      mix rumbo.gen.project "BetterRoute"
      mix rumbo.gen.project "BetterRoute" --label production
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [label: :string])

    case argv do
      [name] ->
        Mix.Task.run("app.start")
        create(name, opts[:label] || "default")

      _ ->
        Mix.raise("Uso: mix rumbo.gen.project \"Nombre del proyecto\" [--label etiqueta]")
    end
  end

  defp create(name, label) do
    case Rumbo.Projects.create_project_with_key(%{name: name}, label) do
      {:ok, %{project: project, raw_key: raw_key}} ->
        Mix.shell().info("""

        Proyecto creado
          id:      #{project.id}
          name:    #{project.name}
          slug:    #{project.slug}

        API key (guárdala ahora; no se puede volver a ver):

          #{raw_key}
        """)

      {:error, changeset} ->
        Mix.raise("No se pudo crear el proyecto: #{inspect(changeset.errors)}")
    end
  end
end
