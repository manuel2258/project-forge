defmodule Forge.AsyncStateTest do
  @moduledoc """
  A test module that runs beside others must not write what the others read (ticket 68).

  The application environment and the system's belong to the whole node: a module that writes one
  with `async: true` changes the answer for every module running at that moment. `Forge.OidcTest` records
  a real flake of exactly this kind, two runs in five, from an async module that had left the fake
  issuer's provider list set. A time limit on the suite would fail on a busy machine for nothing;
  this fails on the pattern, which is what could bring the flake back.

  **What it does not see:** a write made in a support module an async test calls, which is a
  different file. It reads the test files themselves.
  """

  use ExUnit.Case, async: true

  # Every way to write the node's settings that Elixir and Erlang offer.
  @writes ~r/\b(Application\.(put|delete|put_all)_env|System\.(put|delete)_env)\b|:os\.(put|unset)env\b|:application\.(set|unset)_env\b/

  # `use Case, async: true`, with the option on the same line or on one of the next two, once
  # comments are taken off the end of each line (`use Case, async: false # async: true`).
  @async ~r/^[ \t]*use[ \t]+[\w.]+,(?:[^\n]*\n){0,2}?[^\n]*\basync:[ \t]*true\b/m

  test "no async test module writes the application or system environment" do
    offenders =
      for path <- Path.wildcard(Path.join(__DIR__, "../**/*_test.exs")),
          source = File.read!(path),
          Regex.match?(@async, uncommented(source)),
          {line, number} <- source |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(@writes, line),
          do:
            "#{Path.relative_to(path, Path.join(__DIR__, ".."))}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "async: true modules write node-wide state; make the module async: false, or read the " <>
             "setting from the process:\n" <> Enum.join(offenders, "\n")
  end

  defp uncommented(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split(" #", parts: 2) |> hd() end)
  end

  test "the pattern is the one that matters" do
    # Spelt in two pieces, so that this file does not offend against itself.
    assert Regex.match?(@writes, "Application." <> "put_env(:forge, :x, 1)")
    assert Regex.match?(@writes, "  System." <> "delete_env(\"HOME\")")
    refute Regex.match?(@writes, "Application.get_env(:forge, :x)")
    assert Regex.match?(@async, "  use Forge.DataCase, async: true\n")
    refute Regex.match?(@async, "  use Forge.DataCase, async: false\n")
    assert Regex.match?(@writes, "Application." <> "put_all_env(forge: [])")
    assert Regex.match?(@writes, ":os." <> "putenv(~c\"A\", ~c\"b\")")
    assert Regex.match?(@writes, ":application." <> "set_env(:forge, :x, 1)")
    assert Regex.match?(@async, "  use Forge.DataCase,\n    async: true\n")
    # The reach is the comment's: the second line after the `use` is seen, a third is not.
    assert Regex.match?(@async, "  use Forge.DataCase,\n    # a note\n    async: true\n")
    refute Regex.match?(@async, "  use Forge.DataCase,\n    # a\n    # b\n    async: true\n")
    refute Regex.match?(@async, uncommented("  use Forge.DataCase, async: false # async: true\n"))
  end
end
