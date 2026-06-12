defmodule RumboWeb.V1.TokenJSON do
  def show(%{token: token, expires_at: expires_at, subscribe: subscribe, publish: publish}) do
    %{
      data: %{
        token: token,
        expires_at: expires_at,
        subscribe: subscribe,
        publish: publish
      }
    }
  end
end
