defmodule ForgeWorker.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_worker,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [forge_worker: [include_executables_for: [:unix]]]
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

  defp aliases do
    [
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end
end
