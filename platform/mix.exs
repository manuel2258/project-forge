defmodule Forge.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],

      # The floor, not a target. `CLAUDE.md` § Coverage: raise it when the real figure rises,
      # never lower it without a human saying so. Nested under `:summary` because that is where
      # `mix test --cover` reads it; a top-level `:threshold` is silently ignored and leaves the
      # default 90 in force.
      #
      # Test support is ignored so the figure is about production code. `test/support` is on
      # `elixirc_paths` in this env, and a case template or a fixture module is exercised by
      # definition — counting them lifts the percentage without anything being better tested.
      test_coverage: [
        summary: [threshold: 82],
        ignore_modules: [
          Forge.AccountsFixtures,
          Forge.DataCase,
          Forge.FakeWorker,
          Forge.ForgeFixtures,
          Forge.GitFixtures,
          Forge.Push.TestSender,
          ForgeWeb.ChannelCase,
          ForgeWeb.ConnCase
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Forge.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, check: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:pbkdf2_elixir, "~> 2.0"},
      {:swoosh, "~> 1.19"},
      {:md, "~> 0.13"},
      {:html_sanitize_ex, "~> 1.4"},
      {:web_push_elixir, "~> 0.8.0"},
      {:forge_core, path: "../core"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind forge", "esbuild forge"],
      "assets.deploy": [
        "tailwind forge --minify",
        "esbuild forge --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # `test --cover` and not `test`: the threshold in `project/0` is a ratchet, and a ratchet
      # that is not part of the gate is a number nobody reads. See `CLAUDE.md` § Coverage for the
      # rule about which way it may move.
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test --cover"
      ]
    ]
  end
end
