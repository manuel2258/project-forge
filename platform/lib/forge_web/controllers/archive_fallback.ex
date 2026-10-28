defmodule ForgeWeb.ArchiveFallback do
  @moduledoc false

  use ForgeWeb, :controller

  def call(conn, {:error, :unauthorized}),
    do: conn |> put_status(:unauthorized) |> json(%{error: %{reason: "unauthorized"}})

  def call(conn, {:error, :not_found}),
    do: conn |> put_status(:not_found) |> json(%{error: %{reason: "not_found"}})
end
