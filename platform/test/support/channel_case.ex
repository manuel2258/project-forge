defmodule ForgeWeb.ChannelCase do
  @moduledoc """
  Tests that need a channel: the worker socket is the only one the platform has that is not
  LiveView's. Sets up the SQL sandbox the way `Forge.DataCase` does, since a channel talks to
  the database on every message.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint ForgeWeb.Endpoint

      import ForgeWeb.ChannelCase
    end
  end

  setup tags do
    Forge.DataCase.setup_sandbox(tags)
    :ok
  end
end
