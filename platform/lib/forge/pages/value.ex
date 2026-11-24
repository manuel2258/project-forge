defmodule Forge.Pages.Value do
  @moduledoc """
  A store's value: any JSON value — a string, a number, a list, null — kept in a `jsonb` column.
  Ecto's `:map` takes only objects, so the column holds `{"v": value}` and this type wraps and
  unwraps it; nothing outside the column sees the wrapper.

  Whatever Jason decoded is what comes back, so nothing here is a guard: the limits and the shape
  of what a writer sent are `Forge.Pages`'s.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: {:ok, value}

  @impl true
  def dump(value), do: {:ok, %{"v" => value}}

  @impl true
  def load(%{"v" => value}), do: {:ok, value}
  def load(_other), do: :error
end
