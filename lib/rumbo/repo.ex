defmodule Rumbo.Repo do
  use Ecto.Repo,
    otp_app: :rumbo,
    adapter: Ecto.Adapters.Postgres
end
