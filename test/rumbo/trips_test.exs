defmodule Rumbo.TripsTest do
  use Rumbo.DataCase, async: false

  import Rumbo.Fixtures

  alias Rumbo.Topics
  alias Rumbo.Tracking
  alias Rumbo.Trips

  setup do
    on_exit(&stop_tracker_servers/0)
    {:ok, project: project_fixture()}
  end

  @destination %{"lat" => -12.0667, "lng" => -77.1500, "name" => "Cliente"}

  describe "create_trip/2" do
    test "crea el trip y su tracker implícitamente", %{project: project} do
      key = unique_tracker_key()

      assert {:ok, trip} =
               Trips.create_trip(project, %{
                 "tracker" => key,
                 "destination" => @destination,
                 "waypoints" => [%{"lat" => -12.05, "lon" => -77.08, "name" => "Parada 1"}]
               })

      assert trip.status == "active"
      assert trip.tracker.key == key
      assert trip.destination.lat == -12.0667
      assert [%{name: "Parada 1"}] = trip.waypoints
    end

    test "rechaza un segundo trip activo para el mismo tracker", %{project: project} do
      key = unique_tracker_key()
      attrs = %{"tracker" => key, "destination" => @destination}

      assert {:ok, _} = Trips.create_trip(project, attrs)
      assert {:error, changeset} = Trips.create_trip(project, attrs)
      assert %{tracker_id: ["tracker already has an active trip"]} = errors_on(changeset)
    end

    test "rechaza destinos inválidos", %{project: project} do
      assert {:error, changeset} =
               Trips.create_trip(project, %{
                 "tracker" => unique_tracker_key(),
                 "destination" => %{"lat" => 200, "lng" => 0}
               })

      assert %{destination: _} = errors_on(changeset)
    end
  end

  describe "update_trip/3" do
    test "completa un trip y permite abrir otro", %{project: project} do
      key = unique_tracker_key()
      {:ok, trip} = Trips.create_trip(project, %{"tracker" => key, "destination" => @destination})

      assert {:ok, completed} = Trips.update_trip(project, trip.id, %{"status" => "completed"})
      assert completed.status == "completed"
      assert completed.ended_at != nil

      assert {:ok, _} =
               Trips.create_trip(project, %{"tracker" => key, "destination" => @destination})
    end

    test "no permite reactivar un trip terminado", %{project: project} do
      {:ok, trip} =
        Trips.create_trip(project, %{
          "tracker" => unique_tracker_key(),
          "destination" => @destination
        })

      {:ok, _} = Trips.update_trip(project, trip.id, %{"status" => "canceled"})

      assert {:error, changeset} = Trips.update_trip(project, trip.id, %{"status" => "active"})
      assert %{status: ["trip is already canceled"]} = errors_on(changeset)
    end

    test "difunde el cambio de estado en el topic del trip", %{project: project} do
      {:ok, trip} =
        Trips.create_trip(project, %{
          "tracker" => unique_tracker_key(),
          "destination" => @destination
        })

      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.trip(project.id, trip.id))
      {:ok, _} = Trips.update_trip(project, trip.id, %{"status" => "completed"})

      assert_receive %Phoenix.Socket.Broadcast{event: "status", payload: %{status: "completed"}},
                     1_000
    end
  end

  describe "flujo de ETA" do
    test "ingerir una posición con trip activo difunde un evento eta", %{project: project} do
      key = unique_tracker_key()

      {:ok, trip} =
        Trips.create_trip(project, %{
          "tracker" => key,
          "destination" => @destination,
          "waypoints" => [%{"lat" => -12.05, "lng" => -77.08, "name" => "Parada 1"}]
        })

      Phoenix.PubSub.subscribe(Rumbo.PubSub, Topics.trip(project.id, trip.id))

      {:ok, _} =
        Tracking.ingest(project, key, [%{"lat" => -12.0464, "lng" => -77.0428, "speed" => 10.0}])

      assert_receive %Phoenix.Socket.Broadcast{event: "position"}, 1_000
      assert_receive %Phoenix.Socket.Broadcast{event: "eta", payload: eta}, 2_000

      assert eta.trip_id == trip.id
      assert eta.engine == "haversine"
      assert eta.duration_seconds > 0
      # una pierna por waypoint + destino, con eta_at acumulativo
      assert [first, last] = eta.legs
      assert first.name == "Parada 1"
      assert DateTime.compare(last.eta_at, first.eta_at) == :gt

      # el ETA queda persistido en el trip
      :ok = Tracking.flush(project, key)
      {:ok, reloaded} = Trips.fetch_trip(project, trip.id)
      assert reloaded.eta["engine"] == "haversine"
    end
  end
end
