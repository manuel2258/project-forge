# Credo configuration. `mix credo --strict` is part of the quality gate (see CLAUDE.md).
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        disabled: [
          # Fully qualified nested modules inline are fine; forcing aliases hurts readability.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
