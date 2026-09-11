defmodule ForgeWorkerTest do
  use ExUnit.Case
  doctest ForgeWorker

  test "greets the world" do
    assert ForgeWorker.hello() == :world
  end
end
