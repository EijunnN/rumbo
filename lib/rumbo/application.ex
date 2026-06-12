defmodule Rumbo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Rumbo.Eta.Limiter.setup!()

    children =
      [
        RumboWeb.Telemetry,
        Rumbo.Repo,
        {DNSCluster, query: Application.get_env(:rumbo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Rumbo.PubSub},
        # Un proceso por tracker activo, registrado por {project_id, tracker_key}
        {Registry, keys: :unique, name: Rumbo.TrackerRegistry},
        {DynamicSupervisor, name: Rumbo.TrackerSupervisor, strategy: :one_for_one},
        # Cálculos de ETA fuera del proceso del tracker
        {Task.Supervisor, name: Rumbo.TaskSupervisor},
        # Writers agregados de posiciones, sharded por tracker_id
        {PartitionSupervisor,
         child_spec: Rumbo.Tracking.PositionWriter, name: Rumbo.PositionWriters},
        # Circuit breaker de OSRM (dueño de la tabla ETS)
        Rumbo.Eta.Breaker
      ] ++
        partition_manager() ++
        [
          # Start to serve requests, typically the last entry
          RumboWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rumbo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # En tests las particiones las crea la migración; el manager queda apagado
  # para no competir con el sandbox de Ecto.
  defp partition_manager do
    if Application.get_env(:rumbo, :start_partition_manager, true) do
      [Rumbo.Tracking.PartitionManager]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RumboWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
