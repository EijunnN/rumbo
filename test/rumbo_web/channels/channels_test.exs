defmodule RumboWeb.ChannelsTest do
  use RumboWeb.ChannelCase, async: false

  alias Rumbo.Auth.ClientToken
  alias Rumbo.Trips
  alias RumboWeb.UserSocket

  setup do
    on_exit(&stop_tracker_servers/0)
    {:ok, project: project_fixture()}
  end

  defp connect_with_token(project, opts) do
    {token, _expires_at} = ClientToken.issue(project, opts)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "UserSocket" do
    test "conecta con API key", %{project: project} do
      raw_key = api_key_fixture(project)
      assert {:ok, socket} = connect(UserSocket, %{"api_key" => raw_key})
      assert socket.assigns.project_id == project.id
      assert socket.assigns.subscribe == ["*"]
    end

    test "rechaza tokens inválidos y conexiones sin credenciales" do
      assert :error = connect(UserSocket, %{"token" => "basura"})
      assert :error = connect(UserSocket, %{})
    end
  end

  describe "TrackerChannel" do
    test "publisher empuja posiciones y subscriber las recibe", %{project: project} do
      key = unique_tracker_key()

      subscriber = connect_with_token(project, subscribe: ["tracker:#{key}"])
      {:ok, _snapshot, _sub} = subscribe_and_join(subscriber, "tracker:#{key}")

      publisher = connect_with_token(project, publish: ["tracker:#{key}"])
      {:ok, _snapshot, pub} = subscribe_and_join(publisher, "tracker:#{key}")

      ref = push(pub, "position", %{"lat" => -12.05, "lng" => -77.04, "speed" => 8.0})
      assert_reply ref, :ok, %{accepted: 1}

      assert_push "status", %{status: "online"}
      assert_push "position", %{lat: -12.05, lng: -77.04, speed: 8.0}
    end

    test "el snapshot del join trae el último estado", %{project: project} do
      key = unique_tracker_key()

      # estado previo: un ping ya ingerido y persistido
      {:ok, _} = Rumbo.Tracking.ingest(project, key, [%{"lat" => -12.1, "lng" => -77.1}])
      :ok = Rumbo.Tracking.flush(project, key)

      socket = connect_with_token(project, subscribe: ["tracker:#{key}"])
      {:ok, snapshot, _} = subscribe_and_join(socket, "tracker:#{key}")

      assert snapshot.tracker.key == key
      assert snapshot.tracker.online == true
      assert snapshot.tracker.position["lat"] == -12.1
    end

    test "sin scope no hay join ni publish", %{project: project} do
      key = unique_tracker_key()

      socket = connect_with_token(project, subscribe: ["tracker:otro"])
      assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "tracker:#{key}")

      # con subscribe pero sin publish: join ok, push rechazado
      sub_only = connect_with_token(project, subscribe: ["tracker:#{key}"])
      {:ok, _, joined} = subscribe_and_join(sub_only, "tracker:#{key}")

      ref = push(joined, "position", %{"lat" => 0, "lng" => 0})
      assert_reply ref, :error, %{reason: "publish scope required"}
    end

    test "los wildcards de scope funcionan", %{project: project} do
      key = unique_tracker_key()
      socket = connect_with_token(project, subscribe: ["tracker:*"])
      assert {:ok, _, _} = subscribe_and_join(socket, "tracker:#{key}")
    end
  end

  describe "TripChannel" do
    test "snapshot al join y eventos de posición/eta en vivo", %{project: project} do
      key = unique_tracker_key()

      {:ok, trip} =
        Trips.create_trip(project, %{
          "tracker" => key,
          "destination" => %{"lat" => -12.0667, "lng" => -77.15, "name" => "Cliente"}
        })

      socket = connect_with_token(project, subscribe: ["trip:#{trip.id}"])
      {:ok, snapshot, _} = subscribe_and_join(socket, "trip:#{trip.id}")

      assert snapshot.trip.id == trip.id
      assert snapshot.trip.status == "active"

      # un ping del tracker dispara position + eta hacia el canal del trip
      {:ok, _} =
        Rumbo.Tracking.ingest(project, key, [
          %{"lat" => -12.0464, "lng" => -77.0428, "speed" => 10.0}
        ])

      assert_push "position", %{lat: -12.0464}
      assert_push "eta", %{trip_id: trip_id, engine: "haversine"}, 2_000
      assert trip_id == trip.id
    end

    test "no se puede unir a trips de otro proyecto", %{project: project} do
      other = project_fixture()

      {:ok, trip} =
        Trips.create_trip(other, %{
          "tracker" => unique_tracker_key(),
          "destination" => %{"lat" => -12.0, "lng" => -77.0}
        })

      # token del proyecto A con wildcard no abre trips del proyecto B
      socket = connect_with_token(project, subscribe: ["*"])
      assert {:error, _} = subscribe_and_join(socket, "trip:#{trip.id}")
    end
  end
end
