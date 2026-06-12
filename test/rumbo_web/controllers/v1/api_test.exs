defmodule RumboWeb.V1.ApiTest do
  use RumboWeb.ConnCase, async: false

  import Rumbo.Fixtures

  setup %{conn: conn} do
    on_exit(&stop_tracker_servers/0)

    project = project_fixture()
    raw_key = api_key_fixture(project)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: authed, project: project}
  end

  describe "autenticación" do
    test "rechaza requests sin API key" do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/v1/trackers")
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "rechaza API keys inválidas" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer rk_falsa")
        |> get(~p"/v1/trackers")

      assert json_response(conn, 401)
    end

    test "el health check no requiere auth" do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/health")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end

  describe "POST /v1/trackers/:key/positions" do
    test "acepta una posición simple y devuelve policy + watched", %{conn: conn} do
      key = unique_tracker_key()
      conn = post(conn, ~p"/v1/trackers/#{key}/positions", %{lat: -12.05, lng: -77.04})

      assert %{
               "data" => %{
                 "accepted" => 1,
                 "tracker" => ^key,
                 "watched" => false,
                 "policy" => %{"ping_interval_s" => 30, "batch_max_wait_s" => 60}
               }
             } = json_response(conn, 202)
    end

    test "acepta un batch (cola offline)", %{conn: conn} do
      key = unique_tracker_key()

      conn =
        post(conn, ~p"/v1/trackers/#{key}/positions", %{
          positions: [
            %{lat: -12.05, lng: -77.04, recorded_at: "2026-06-11T15:00:00Z"},
            %{lat: -12.06, lng: -77.05, recorded_at: "2026-06-11T15:01:00Z"}
          ]
        })

      assert %{"data" => %{"accepted" => 2}} = json_response(conn, 202)
    end

    test "422 con detalle si una posición es inválida", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/trackers/#{unique_tracker_key()}/positions", %{
          positions: [%{lat: -12.05, lng: -77.04}, %{lat: 999, lng: 0}]
        })

      assert %{"error" => %{"code" => "invalid_position", "details" => %{"index" => 1}}} =
               json_response(conn, 422)
    end
  end

  describe "GET /v1/trackers" do
    test "lista trackers con estado online", %{conn: conn, project: project} do
      key = unique_tracker_key()
      post(conn, ~p"/v1/trackers/#{key}/positions", %{lat: -12.05, lng: -77.04})
      :ok = Rumbo.Tracking.flush(project, key)

      conn = get(conn, ~p"/v1/trackers/#{key}")

      assert %{
               "data" => %{
                 "key" => ^key,
                 "online" => true,
                 "position" => %{"lat" => -12.05, "lng" => -77.04}
               }
             } = json_response(conn, 200)
    end

    test "404 para trackers desconocidos", %{conn: conn} do
      conn = get(conn, ~p"/v1/trackers/no-existe")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /v1/trackers/:key/positions" do
    test "devuelve el historial", %{conn: conn, project: project} do
      key = unique_tracker_key()

      post(conn, ~p"/v1/trackers/#{key}/positions", %{
        positions: [
          %{lat: -12.05, lng: -77.04, recorded_at: "2026-06-11T15:00:00Z"},
          %{lat: -12.06, lng: -77.05, recorded_at: "2026-06-11T15:01:00Z"}
        ]
      })

      :ok = Rumbo.Tracking.flush(project, key)

      conn = get(conn, ~p"/v1/trackers/#{key}/positions?limit=1")
      assert %{"data" => [%{"lat" => -12.06}]} = json_response(conn, 200)
    end

    test "422 si from no es ISO8601", %{conn: conn} do
      conn = get(conn, ~p"/v1/trackers/x/positions?from=ayer")
      assert %{"error" => %{"code" => "invalid_param"}} = json_response(conn, 422)
    end
  end

  describe "trips" do
    test "ciclo completo: crear, consultar, completar", %{conn: conn} do
      key = unique_tracker_key()

      created =
        post(conn, ~p"/v1/trips", %{
          tracker: key,
          destination: %{lat: -12.0667, lng: -77.15, name: "Cliente"},
          waypoints: [%{lat: -12.05, lng: -77.08}],
          metadata: %{order_id: "ORD-1"}
        })

      assert %{"data" => %{"id" => trip_id, "status" => "active", "tracker" => ^key}} =
               json_response(created, 201)

      shown = get(conn, ~p"/v1/trips/#{trip_id}")
      assert %{"data" => %{"destination" => %{"name" => "Cliente"}}} = json_response(shown, 200)

      updated = patch(conn, ~p"/v1/trips/#{trip_id}", %{status: "completed"})
      assert %{"data" => %{"status" => "completed"}} = json_response(updated, 200)
    end

    test "409 semántico (422 changeset) para doble trip activo", %{conn: conn} do
      key = unique_tracker_key()
      attrs = %{tracker: key, destination: %{lat: -12.0, lng: -77.0}}

      assert json_response(post(conn, ~p"/v1/trips", attrs), 201)

      assert %{"error" => %{"code" => "invalid_params"}} =
               json_response(post(conn, ~p"/v1/trips", attrs), 422)
    end

    test "404 para trips de otro proyecto", %{conn: conn} do
      other_project = project_fixture()
      other_key = api_key_fixture(other_project)

      created =
        post(conn, ~p"/v1/trips", %{
          tracker: unique_tracker_key(),
          destination: %{lat: -12.0, lng: -77.0}
        })

      %{"data" => %{"id" => trip_id}} = json_response(created, 201)

      foreign =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{other_key}")
        |> get(~p"/v1/trips/#{trip_id}")

      assert json_response(foreign, 404)
    end
  end

  describe "POST /v1/tokens" do
    test "emite un token de cliente con scopes", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/tokens", %{
          subscribe: ["trip:*"],
          publish: ["tracker:driver_42"],
          ttl_seconds: 600
        })

      assert %{"data" => %{"token" => token, "expires_at" => _}} = json_response(conn, 201)
      assert {:ok, claims} = Rumbo.Auth.ClientToken.verify(token)
      assert claims.subscribe == ["trip:*"]
      assert claims.publish == ["tracker:driver_42"]
    end

    test "rechaza scopes malformados", %{conn: conn} do
      conn = post(conn, ~p"/v1/tokens", %{subscribe: ["cualquier cosa"]})
      assert %{"error" => %{"code" => "invalid_scopes"}} = json_response(conn, 422)
    end
  end
end
