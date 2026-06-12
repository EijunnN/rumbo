defmodule RumboWeb.ChannelCase do
  @moduledoc """
  Test case para canales. Igual que ConnCase pero con `Phoenix.ChannelTest`.
  Los tests de canales deben ser `async: false`: los TrackerServer son
  procesos externos que necesitan el sandbox en modo compartido.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint RumboWeb.Endpoint

      import Phoenix.ChannelTest
      import RumboWeb.ChannelCase
      import Rumbo.Fixtures
    end
  end

  setup tags do
    Rumbo.DataCase.setup_sandbox(tags)
    :ok
  end
end
