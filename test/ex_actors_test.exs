defmodule ExActorsTest do
  use ExUnit.Case
  doctest ExActors

  test "greets the world" do
    assert ExActors.hello() == :world
  end
end
