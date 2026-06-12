defmodule RumboWeb.V1.FallbackController do
  @moduledoc """
  Traduce los errores de los contextos a respuestas JSON consistentes:

      {"error": {"code": "...", "message": "...", "details": {...}}}
  """

  use RumboWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    error(conn, 422, "invalid_params", "Validation failed", changeset_errors(changeset))
  end

  def call(conn, {:error, {:invalid_position, index, changeset}}) do
    error(conn, 422, "invalid_position", "Position at index #{index} is invalid", %{
      index: index,
      errors: changeset_errors(changeset)
    })
  end

  def call(conn, {:error, :not_found}) do
    error(conn, 404, "not_found", "Resource not found")
  end

  def call(conn, {:error, :unauthorized}) do
    error(conn, 401, "unauthorized", "Invalid API key")
  end

  def call(conn, {:error, :invalid_tracker_key}) do
    error(
      conn,
      422,
      "invalid_tracker_key",
      "Tracker key must match [A-Za-z0-9][A-Za-z0-9_.:-]{0,127}"
    )
  end

  def call(conn, {:error, :no_positions}) do
    error(conn, 422, "no_positions", "Send a position object or a non-empty positions array")
  end

  def call(conn, {:error, :batch_too_large}) do
    error(conn, 422, "batch_too_large", "At most 500 positions per request")
  end

  def call(conn, {:error, :invalid_scopes}) do
    error(
      conn,
      422,
      "invalid_scopes",
      "Scopes must look like tracker:<key>, trip:<id>, tracker:* or *"
    )
  end

  def call(conn, {:error, {:invalid_param, name}}) do
    error(conn, 422, "invalid_param", "Invalid value for parameter #{name}")
  end

  defp error(conn, status, code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body

    conn
    |> put_status(status)
    |> json(%{error: body})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
