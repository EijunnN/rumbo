defmodule Rumbo.TrackingTest do
  # async: false — los TrackerServer son procesos externos al test que
  # necesitan el sandbox compartido.
  use Rumbo.DataCase, async: false

  import Rumbo.Fixtures

  alias Rumbo.Tracking
  alias Rumbo.Tracking.Position
  alias Rumbo.Topics

  setup do
    on_exit(&stop_tracker_servers/0)
    {:ok, project: project_fixture()}
  end

  describe "ingest/3" do
    test "crea el tracker implícitamente y acepta el lote", %{project: project} do
      key = unique_tracker_key()

      assert {:ok, %{accepted: 2, tracker: ^key}} =
               Tracking.ingest(project, key, [
                 %{"lat" => -12.05, "lng" => -77.04},
                 %{"lat" => -12.06, "lng" => -77.05}
               ])

      assert %{key: ^key} = Tracking.get_tracker(project, key)
    end

    test "difunde la posición y el estado online por PubSub", %{project: project} do
      key = unique_tracker_key()
      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.tracker(project.id, key))

      {:ok, _} =
        Tracking.ingest(project, key, [%{"lat" => -12.05, "lng" => -77.04, "speed" => 8.0}])

      assert_receive %Phoenix.Socket.Broadcast{event: "status", payload: %{status: "online"}},
                     1_000

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "position",
                       payload: %{tracker: ^key, lat: -12.05, lng: -77.04, speed: 8.0}
                     },
                     1_000
    end

    test "persiste posiciones con dedupe por recorded_at", %{project: project} do
      key = unique_tracker_key()
      at = "2026-06-11T15:00:00Z"

      ping = %{"lat" => -12.05, "lng" => -77.04, "recorded_at" => at}

      # El mismo ping dos veces (reintento de cola offline)
      {:ok, _} = Tracking.ingest(project, key, [ping])
      {:ok, _} = Tracking.ingest(project, key, [ping])
      :ok = Tracking.flush(project, key)

      assert Repo.aggregate(Position, :count) == 1
    end

    test "actualiza el snapshot del tracker al hacer flush", %{project: project} do
      key = unique_tracker_key()

      {:ok, _} = Tracking.ingest(project, key, [%{"lat" => -12.05, "lng" => -77.04}])
      :ok = Tracking.flush(project, key)

      tracker = Tracking.get_tracker(project, key)
      assert tracker.last_seen_at != nil
      assert tracker.last_position["lat"] == -12.05
      assert Tracking.online?(project, tracker)
    end

    test "normaliza alias de llaves del mundo real", %{project: project} do
      key = unique_tracker_key()
      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.tracker(project.id, key))

      raw = %{
        "latitude" => -12.05,
        "lon" => -77.04,
        "bearing" => 120.0,
        "batteryLevel" => 88,
        "timestamp" => 1_780_000_000_000
      }

      assert {:ok, %{accepted: 1}} = Tracking.ingest(project, key, [raw])

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "position",
                       payload: %{lat: -12.05, lng: -77.04, heading: 120.0, battery: 88.0}
                     },
                     1_000
    end

    test "rechaza el lote completo si alguna posición es inválida", %{project: project} do
      assert {:error, {:invalid_position, 1, _changeset}} =
               Tracking.ingest(project, unique_tracker_key(), [
                 %{"lat" => -12.05, "lng" => -77.04},
                 %{"lat" => 999, "lng" => -77.04}
               ])
    end

    test "valida formato de tracker key y lotes vacíos", %{project: project} do
      assert {:error, :invalid_tracker_key} = Tracking.ingest(project, "con espacios", [%{}])
      assert {:error, :invalid_tracker_key} = Tracking.ingest(project, nil, [%{}])
      assert {:error, :no_positions} = Tracking.ingest(project, "ok_key", [])
    end
  end

  describe "list_positions/3" do
    test "respeta filtros de rango y límite", %{project: project} do
      key = unique_tracker_key()

      pings =
        for minute <- 1..5 do
          %{"lat" => -12.0, "lng" => -77.0, "recorded_at" => "2026-06-11T15:0#{minute}:00Z"}
        end

      {:ok, _} = Tracking.ingest(project, key, pings)
      :ok = Tracking.flush(project, key)

      {:ok, all} = Tracking.list_positions(project, key)
      assert length(all) == 5
      # más recientes primero
      assert [%{recorded_at: ~U[2026-06-11 15:05:00.000000Z]} | _] = all

      {:ok, limited} = Tracking.list_positions(project, key, limit: 2)
      assert length(limited) == 2

      {:ok, ranged} =
        Tracking.list_positions(project, key,
          from: ~U[2026-06-11 15:02:00Z],
          to: ~U[2026-06-11 15:03:00Z]
        )

      assert length(ranged) == 2
    end
  end
end
