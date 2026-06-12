defmodule RumboWeb.Router do
  use RumboWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug RumboWeb.Plugs.Authenticate
  end

  scope "/", RumboWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/v1", RumboWeb.V1 do
    pipe_through [:api, :authenticated]

    # Ingesta de posiciones (single o batch)
    post "/positions", PositionController, :create
    post "/trackers/:key/positions", PositionController, :create

    # Trackers y su historial
    get "/trackers", TrackerController, :index
    get "/trackers/:key", TrackerController, :show
    put "/trackers/:key", TrackerController, :upsert
    get "/trackers/:key/positions", PositionController, :index

    # Trips (sesiones de tracking con destino y ETA)
    resources "/trips", TripController, only: [:index, :show, :create, :update]

    # Tokens efímeros para clientes finales (sockets)
    post "/tokens", TokenController, :create
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:rumbo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: RumboWeb.Telemetry
    end
  end
end
