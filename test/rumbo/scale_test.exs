defmodule Rumbo.ScaleTest do
  @moduledoc """
  Tests de los componentes de escala: asignación de nodos, limiter de ETA,
  circuit breaker de OSRM y el writer agregado.
  """

  # async: false — limiter y breaker son estado global del nodo.
  use Rumbo.DataCase, async: false

  import Rumbo.Fixtures

  alias Rumbo.Cluster
  alias Rumbo.Eta
  alias Rumbo.Eta.{Breaker, Limiter}
  alias Rumbo.Projects.Project
  alias Rumbo.Tracking
  alias Rumbo.Tracking.Position

  setup do
    on_exit(&stop_tracker_servers/0)
    :ok
  end

  describe "Cluster.owner_node/2" do
    test "con un solo nodo el dueño siempre es local" do
      assert Cluster.owner_node({"p1", "driver_1"}) == node()
      assert Cluster.local?({"p1", "driver_1"})
    end

    test "es determinista y estable sobre una lista de nodos" do
      nodes = [:a@host, :b@host, :c@host]
      key = {"project", "driver_42"}

      owner = Cluster.owner_node(key, nodes)
      assert owner in nodes
      # mismo input → mismo dueño, sin importar el orden de la lista
      assert Cluster.owner_node(key, Enum.reverse(nodes)) == owner
      assert Cluster.owner_node(key, Enum.shuffle(nodes)) == owner
    end

    test "distribuye keys distintas entre nodos" do
      nodes = [:a@host, :b@host, :c@host, :d@host]

      owners =
        for i <- 1..200, uniq: true do
          Cluster.owner_node({"project", "driver_#{i}"}, nodes)
        end

      # con 200 keys, todos los nodos deberían recibir alguna
      assert Enum.sort(owners) == Enum.sort(nodes)
    end
  end

  describe "Eta.Limiter" do
    test "limita la concurrencia y se libera" do
      original = Application.get_env(:rumbo, :eta_max_concurrency)
      Application.put_env(:rumbo, :eta_max_concurrency, 2)
      on_exit(fn -> Application.put_env(:rumbo, :eta_max_concurrency, original) end)

      base = Limiter.in_flight()

      assert :ok = Limiter.acquire()
      assert :ok = Limiter.acquire()
      assert :busy = Limiter.acquire()

      assert :ok = Limiter.release()
      assert :ok = Limiter.acquire()

      # limpiar los 2 slots tomados
      Limiter.release()
      Limiter.release()
      assert Limiter.in_flight() == base
    end
  end

  describe "Eta.Breaker + fallback" do
    test "abre el circuito tras 5 fallos y se recupera con un éxito" do
      url = "http://osrm-test-#{System.unique_integer([:positive])}"

      assert Breaker.available?(url)

      for _ <- 1..4, do: Breaker.record_failure(url)
      assert Breaker.available?(url)

      Breaker.record_failure(url)
      refute Breaker.available?(url)

      Breaker.record_success(url)
      assert Breaker.available?(url)
    end

    test "OSRM inalcanzable degrada a haversine sin dejar de emitir ETA" do
      # puerto cerrado: el request falla rápido
      project = %Project{
        id: Ecto.UUID.generate(),
        settings: %{"eta" => %{"engine" => "osrm", "osrm_url" => "http://localhost:1"}}
      }

      from = %{lat: -12.0464, lng: -77.0428}
      destination = %{lat: -12.0667, lng: -77.15}

      assert {:ok, route} = Eta.calculate(project, from, [destination])
      assert route.engine == "haversine"
      assert route.degraded == true
      assert route.duration_seconds > 0
    end

    test "engine osrm sin osrm_url degrada a haversine" do
      project = %Project{id: Ecto.UUID.generate(), settings: %{"eta" => %{"engine" => "osrm"}}}

      assert {:ok, %{engine: "haversine", degraded: true}} =
               Eta.calculate(project, %{lat: 0.0, lng: 0.0}, [%{lat: 1.0, lng: 1.0}])
    end
  end

  describe "PositionWriter" do
    test "agrega filas de varios trackers en el mismo flush", %{} do
      project = project_fixture()
      keys = for i <- 1..5, do: "writer_#{i}_#{System.unique_integer([:positive])}"

      for key <- keys do
        {:ok, _} =
          Tracking.ingest(project, key, [
            %{"lat" => -12.0, "lng" => -77.0, "recorded_at" => "2026-06-12T10:00:00Z"}
          ])
      end

      # una sola pasada de flush escribe todo y actualiza los 5 snapshots
      for key <- keys, do: :ok = Tracking.flush(project, key)

      assert Repo.aggregate(Position, :count) == 5

      for key <- keys do
        tracker = Tracking.get_tracker(project, key)
        assert tracker.last_seen_at != nil
        assert tracker.last_position["lat"] == -12.0
      end
    end

    test "posiciones con recorded_at antiguo caen en la partición default" do
      project = project_fixture()
      key = unique_tracker_key()

      # 2020: ninguna partición mensual lo cubre → partición DEFAULT
      {:ok, _} =
        Tracking.ingest(project, key, [
          %{"lat" => -12.0, "lng" => -77.0, "recorded_at" => "2020-01-15T10:00:00Z"}
        ])

      :ok = Tracking.flush(project, key)

      {:ok, [position]} = Tracking.list_positions(project, key)
      assert position.recorded_at == ~U[2020-01-15 10:00:00.000000Z]
    end
  end
end
