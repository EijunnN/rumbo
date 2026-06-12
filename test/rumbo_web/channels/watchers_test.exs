defmodule RumboWeb.WatchersTest do
  @moduledoc """
  Tests del mecanismo de ahorro de batería: policy server-driven y eventos
  `watchers` por presencia de espectadores.
  """

  use RumboWeb.ChannelCase, async: false

  alias Rumbo.Auth.ClientToken
  alias Rumbo.Tracking.Policy
  alias Rumbo.Trips
  alias RumboWeb.UserSocket

  @destination %{"lat" => -12.0667, "lng" => -77.15, "name" => "Cliente"}

  setup do
    on_exit(&stop_tracker_servers/0)
    {:ok, project: project_fixture()}
  end

  defp connect_with_token(project, opts) do
    {token, _expires_at} = ClientToken.issue(project, opts)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "Policy" do
    test "defaults razonables sin configuración", %{project: project} do
      policy = Policy.for_project(project)
      assert policy.ping_interval_s == 30
      assert policy.watched_ping_interval_s == 10
      assert policy.min_displacement_m == 25
      assert policy.batch_max_wait_s == 60
    end

    test "el proyecto sobreescribe campos puntuales" do
      project =
        project_fixture(%{
          settings: %{"tracking" => %{"policy" => %{"ping_interval_s" => 60}}}
        })

      policy = Policy.for_project(project)
      assert policy.ping_interval_s == 60
      # el resto conserva defaults
      assert policy.batch_max_wait_s == 60
    end
  end

  describe "watchers en vivo" do
    test "el publisher se entera cuando alguien mira su trip y cuando deja de mirar",
         %{project: project} do
      key = unique_tracker_key()
      {:ok, trip} = Trips.create_trip(project, %{"tracker" => key, "destination" => @destination})

      publisher = connect_with_token(project, publish: ["tracker:#{key}"])
      {:ok, snapshot, _pub} = subscribe_and_join(publisher, "tracker:#{key}")

      # el snapshot trae la policy y el estado inicial sin espectadores
      assert snapshot.watched == false
      assert snapshot.policy.ping_interval_s == 30

      # un cliente final abre el mapa del trip
      watcher = connect_with_token(project, subscribe: ["trip:#{trip.id}"])
      {:ok, _, watcher_socket} = subscribe_and_join(watcher, "trip:#{trip.id}")

      assert_push "watchers", %{watched: true, watchers: 1}, 1_000

      # el cliente cierra el mapa
      Process.unlink(watcher_socket.channel_pid)
      ref = leave(watcher_socket)
      assert_reply ref, :ok

      assert_push "watchers", %{watched: false, watchers: 0}, 1_000
    end

    test "un suscriptor del tracker (dashboard) también cuenta", %{project: project} do
      key = unique_tracker_key()

      publisher = connect_with_token(project, publish: ["tracker:#{key}"])
      {:ok, %{watched: false}, _pub} = subscribe_and_join(publisher, "tracker:#{key}")

      dashboard = connect_with_token(project, subscribe: ["tracker:#{key}"])
      {:ok, _, _} = subscribe_and_join(dashboard, "tracker:#{key}")

      assert_push "watchers", %{watched: true, watchers: 1}, 1_000
    end

    test "un segundo publisher no cuenta como espectador", %{project: project} do
      key = unique_tracker_key()

      publisher = connect_with_token(project, publish: ["tracker:#{key}"])
      {:ok, _, _} = subscribe_and_join(publisher, "tracker:#{key}")

      other_device = connect_with_token(project, publish: ["tracker:#{key}"])
      {:ok, snapshot, _} = subscribe_and_join(other_device, "tracker:#{key}")

      assert snapshot.watched == false
      refute_push "watchers", %{watched: true}, 300
    end
  end
end
