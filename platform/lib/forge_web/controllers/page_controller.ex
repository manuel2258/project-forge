defmodule ForgeWeb.PageController do
  use ForgeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
