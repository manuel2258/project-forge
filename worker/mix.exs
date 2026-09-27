defmodule ForgeWorker.MixProject do
  use Mix.Project

  # The repository's one version, read rather than repeated: `flake.nix` reads the same file for
  # the release and the image tag, and a version used to mean editing the same string in five
  # places and getting four of them. `bin/release` moves it; nothing else should.
  @version String.trim(File.read!(Path.expand("../VERSION", __DIR__)))

  def project do
    [
      app: :forge_worker,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [forge_worker: [include_executables_for: [:unix]]],
      # The floor, not a target. `CLAUDE.md` § Coverage: raise it when the real figure rises,
      # never lower it without a human saying so. Nested under `:summary` because that is where
      # `mix test --cover` reads it; a top-level `:threshold` is silently ignored and leaves the
      # default 90 in force.
      #
      # Test support is ignored so the figure is about production code. `test/support` is on
      # `elixirc_paths` in this env, and a fixture module is exercised by definition — counting it
      # lifts the percentage without anything being better tested.
      test_coverage: [
        summary: [threshold: 89],
        ignore_modules: [ForgeWorker.Fixtures]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [preferred_envs: [check: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ForgeWorker.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:forge_core, path: "../core"},
      {:jason, "~> 1.4"},
      # The channel client the plan names, and an HTTP client for the platform's blob store.
      # Slipstream already brings Mint, which is what Req's Finch uses, so this is one
      # transport, not two.
      {:slipstream, "~> 1.2"},
      {:req, "~> 0.5"},
      # Test only: Req.Test serves requests from a plug instead of the network, so the store
      # can be answered without a platform and without stubbing Req itself.
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # `test --cover` and not `test`: the threshold in `project/0` is a ratchet, and a ratchet that
  # is not part of the gate is a number nobody reads. See `CLAUDE.md` § Coverage for the rule
  # about which way it may move.
  defp aliases do
    [
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test --cover"
      ]
    ]
  end
end
