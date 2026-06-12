defmodule Rumbo.Auth.Scope do
  @moduledoc """
  Scopes de canales para tokens de cliente.

  Un scope es el nombre de un topic (`"tracker:driver_42"`, `"trip:<uuid>"`),
  un wildcard de sufijo (`"tracker:*"`) o el comodín total `"*"`.
  """

  @scope_format ~r/^(\*|(tracker|trip):\S+)$/

  def allows?(scopes, topic) when is_list(scopes) do
    Enum.any?(scopes, fn scope ->
      scope == "*" or scope == topic or wildcard_match?(scope, topic)
    end)
  end

  def allows?(_, _), do: false

  def valid?(scope), do: is_binary(scope) and Regex.match?(@scope_format, scope)

  defp wildcard_match?(scope, topic) do
    case String.split(scope, "*", parts: 2) do
      [prefix, ""] -> String.starts_with?(topic, prefix)
      _ -> false
    end
  end
end
