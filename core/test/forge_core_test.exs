defmodule ForgeCoreTest do
  use ExUnit.Case
  doctest ForgeCore

  test "greets the world" do
    assert ForgeCore.hello() == :world
  end
end
