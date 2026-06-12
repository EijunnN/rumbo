defmodule Rumbo.GeoTest do
  use ExUnit.Case, async: true

  alias Rumbo.Geo

  # Plaza de Armas de Lima → Plaza Matriz del Callao: ~12.5 km en línea recta
  @lima %{lat: -12.0464, lng: -77.0428}
  @callao %{lat: -12.0667, lng: -77.1500}

  test "haversine_meters da distancias razonables" do
    distance = Geo.haversine_meters(@lima, @callao)
    assert_in_delta distance, 11_900, 500
  end

  test "haversine_meters es cero para el mismo punto" do
    assert Geo.haversine_meters(@lima, @lima) == 0.0
  end

  describe "normalize_point/1" do
    test "acepta alias de llaves y conserva extras" do
      assert {:ok, point} =
               Geo.normalize_point(%{"latitude" => -12.0, "lon" => -77.0, "name" => "Almacén"})

      assert point == %{lat: -12.0, lng: -77.0, name: "Almacén"}
    end

    test "acepta llaves atom" do
      assert {:ok, %{lat: 1.5, lng: 2.5}} = Geo.normalize_point(%{lat: 1.5, lng: 2.5})
    end

    test "rechaza coordenadas fuera de rango o faltantes" do
      assert :error = Geo.normalize_point(%{"lat" => 91, "lng" => 0})
      assert :error = Geo.normalize_point(%{"lat" => 0, "lng" => 181})
      assert :error = Geo.normalize_point(%{"lat" => 10})
      assert :error = Geo.normalize_point("no es un mapa")
    end
  end
end
