defmodule Rumbo.Fixtures do
  @moduledoc """
  Datos de prueba y limpieza de procesos vivos entre tests.
  """

  alias Rumbo.Projects

  def project_fixture(attrs \\ %{}) do
    defaults = %{name: "Proyecto #{System.unique_integer([:positive])}"}
    {:ok, project} = Projects.create_project(Map.merge(defaults, attrs))
    project
  end

  def api_key_fixture(project, label \\ "test") do
    {:ok, _api_key, raw_key} = Projects.create_api_key(project, label)
    raw_key
  end

  def unique_tracker_key, do: "tracker_#{System.unique_integer([:positive])}"

  @doc """
  Detiene todos los TrackerServer vivos y vacía los writers. Registrar con
  `on_exit/1` en tests que ingieren posiciones, ANTES de que el sandbox
  cierre su conexión (los on_exit corren en orden inverso al registro, y el
  del sandbox se registra primero en setup).
  """
  def stop_tracker_servers do
    Rumbo.TrackerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Rumbo.TrackerSupervisor, pid)
    end)

    Rumbo.Tracking.PositionWriter.flush_all()
  end
end
