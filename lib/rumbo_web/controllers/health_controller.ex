defmodule RumboWeb.HealthController do
  use RumboWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
