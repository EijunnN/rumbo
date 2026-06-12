defmodule Rumbo.EtaTest do
  use ExUnit.Case, async: true

  alias Rumbo.Eta
  alias Rumbo.Projects.Project

  @from %{lat: -12.0464, lng: -77.0428}
  @stop %{lat: -12.0600, lng: -77.0800, name: "Parada 1"}
  @destination %{lat: -12.0667, lng: -77.1500}

  defp project(settings \\ %{}), do: %Project{id: Ecto.UUID.generate(), settings: settings}

  describe "settings/1" do
    test "aplica defaults cuando no hay configuración" do
      settings = Eta.settings(project())
      assert settings.engine == "haversine"
      assert settings.throttle_seconds == 30
      assert settings.circuity == 1.3
    end

    test "el proyecto puede sobrescribir valores puntuales" do
      settings =
        Eta.settings(
          project(%{"eta" => %{"engine" => "osrm", "osrm_url" => "http://localhost:5000"}})
        )

      assert settings.engine == "osrm"
      assert settings.osrm_url == "http://localhost:5000"
      # el resto conserva defaults
      assert settings.throttle_meters == 150
    end
  end

  describe "calculate/4 con haversine" do
    test "devuelve una pierna por punto con totales consistentes" do
      assert {:ok, route} = Eta.calculate(project(), @from, [@stop, @destination])

      assert route.engine == "haversine"
      assert length(route.legs) == 2
      assert route.distance_meters > 0

      assert_in_delta route.distance_meters,
                      route.legs |> Enum.map(& &1.distance_meters) |> Enum.sum(),
                      0.001

      assert_in_delta route.duration_seconds,
                      route.legs |> Enum.map(& &1.duration_seconds) |> Enum.sum(),
                      0.001
    end

    test "usa la velocidad actual cuando el tracker se mueve" do
      {:ok, fast} = Eta.calculate(project(), @from, [@destination], speed_mps: 20.0)
      {:ok, slow} = Eta.calculate(project(), @from, [@destination], speed_mps: 10.0)

      assert fast.duration_seconds < slow.duration_seconds
    end

    test "cae a la velocidad de crucero cuando está detenido" do
      # 0 m/s produciría duración infinita; debe usar fallback_speed_kmh
      {:ok, route} = Eta.calculate(project(), @from, [@destination], speed_mps: 0.0)
      assert route.duration_seconds > 0
      refute route.duration_seconds == :infinity
    end
  end

  describe "calculate/4 con osrm" do
    test "sin osrm_url degrada a haversine en vez de fallar" do
      assert {:ok, route} =
               Eta.calculate(project(%{"eta" => %{"engine" => "osrm"}}), @from, [@destination])

      assert route.engine == "haversine"
      assert route.degraded == true
      assert route.degraded_reason =~ "osrm_url_not_configured"
    end
  end
end
