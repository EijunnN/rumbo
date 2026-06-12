defmodule Rumbo.Eta.Osrm do
  @moduledoc """
  Motor de ETA contra un servidor OSRM (`/route/v1`). Se activa por proyecto:

      settings: {"eta": {"engine": "osrm", "osrm_url": "http://localhost:5000"}}
  """

  @behaviour Rumbo.Eta.Engine

  @impl true
  def route(from, waypoints, opts) do
    settings = Keyword.fetch!(opts, :settings)

    case settings.osrm_url do
      nil -> {:error, :osrm_url_not_configured}
      base_url -> request(base_url, settings.profile, [from | waypoints])
    end
  end

  defp request(base_url, profile, points) do
    coords = Enum.map_join(points, ";", fn p -> "#{p.lng},#{p.lat}" end)
    url = "#{String.trim_trailing(base_url, "/")}/route/v1/#{profile}/#{coords}"

    request_opts = [
      params: [overview: "false", alternatives: "false", steps: "false"],
      retry: false,
      receive_timeout: 5_000
    ]

    case Req.get(url, request_opts) do
      {:ok, %{status: 200, body: %{"code" => "Ok", "routes" => [route | _]}}} ->
        legs =
          Enum.map(route["legs"], fn leg ->
            %{distance_meters: leg["distance"], duration_seconds: leg["duration"]}
          end)

        {:ok,
         %{
           distance_meters: route["distance"],
           duration_seconds: route["duration"],
           legs: legs
         }}

      {:ok, %{status: 200, body: %{"code" => code}}} ->
        {:error, {:osrm_no_route, code}}

      {:ok, %{status: status}} ->
        {:error, {:osrm_status, status}}

      {:error, exception} ->
        {:error, {:osrm_unreachable, Exception.message(exception)}}
    end
  end
end
