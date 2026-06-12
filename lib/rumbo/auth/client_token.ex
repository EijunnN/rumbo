defmodule Rumbo.Auth.ClientToken do
  @moduledoc """
  Tokens efímeros y firmados para clientes finales (browser/mobile).

  El backend del consumidor los emite vía `POST /v1/tokens` con su API key y
  los entrega a sus clientes, que se conectan al socket con ellos. Llevan el
  proyecto y los scopes de subscribe/publish; nunca exponen la API key.
  """

  alias Rumbo.Projects.Project

  @salt "rumbo client token"
  @default_ttl 3600
  @max_ttl 60 * 60 * 24 * 7

  def issue(%Project{} = project, opts \\ []) do
    ttl = min(opts[:ttl_seconds] || @default_ttl, @max_ttl)
    exp = System.system_time(:second) + ttl

    claims = %{
      project_id: project.id,
      subscribe: opts[:subscribe] || [],
      publish: opts[:publish] || [],
      exp: exp
    }

    token = Phoenix.Token.sign(RumboWeb.Endpoint, @salt, claims)
    {token, DateTime.from_unix!(exp)}
  end

  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(RumboWeb.Endpoint, @salt, token, max_age: @max_ttl) do
      {:ok, %{exp: exp} = claims} ->
        if System.system_time(:second) < exp do
          {:ok, claims}
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  def max_ttl, do: @max_ttl
end
