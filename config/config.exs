# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rumbo,
  ecto_repos: [Rumbo.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  # Máximo de cálculos de ETA concurrentes por nodo (ver Rumbo.Eta.Limiter)
  eta_max_concurrency: 200

# Configure the endpoint
config :rumbo, RumboWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RumboWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rumbo.PubSub,
  live_view: [signing_salt: "FU8qsVSI"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
