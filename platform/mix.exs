defmodule Forge.MixProject do
  use Mix.Project

  # The repository's one version, read rather than repeated: `flake.nix` reads the same file for
  # the release and the image tag, and a version used to mean editing the same string in five
  # places and getting four of them. `bin/release` moves it; nothing else should.
  @version String.trim(File.read!(Path.expand("../VERSION", __DIR__)))

  def project do
    [
      app: :forge,
      version: @version,
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
      #
      # **The floor follows the lowest figure a run produces, not the highest.** The queue, the
      # scheduler and the worker sweeps run on timers, so which of their branches a run reaches
      # depends on how it was scheduled and the total moves between runs, by as much as 0.1
      # points on one tree: measured three times on one it read 89.12% to 89.21%. A floor set from
      # the top of that range would fail runs with nothing wrong, and a gate that fails at random
      # is a gate people learn to re-run — so the floor is raised only once the *lowest* figure
      # clears it. It is 91 since the project-token branch, whose two full runs (on trees a few
      # lines apart) read 91.20% and 91.27%; before it, 90 since the ticket-types branch, whose
      # three runs read 90.13%, 90.06% and 90.06%. The next raise waits until the lowest clears 92.
      test_coverage: [
        summary: [threshold: 93],
        ignore_modules: [
          Forge.AccountsFixtures,
          Forge.DataCase,
          Forge.FakeIssuer,
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
      preferred_envs: [precommit: :test, check: :test, "forge.look": :test]
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
      # Declared rather than inherited: it was already in the tree behind `web_push_elixir`,
      # and `Forge.Provider.Hetzner` is the first thing here to depend on it directly.
      {:req, "~> 0.7"},
      {:swoosh, "~> 1.19"},
      # The SMTP transport behind `Swoosh.Adapters.SMTP`, which swoosh does not carry itself.
      # Without it the only adapter a release could configure was the local mailbox, and
      # `docs/deploy.md` § Known limits had to say magic-link login does not work.
      {:gen_smtp, "~> 1.2"},
      {:md, "~> 0.13"},
      {:html_sanitize_ex, "~> 1.4"},
      {:web_push_elixir, "~> 0.8.0"},
      # The OIDC client behind `Forge.Accounts.Oidc`. Hand-rolling one means owning JWKS
      # fetching, `kid` selection, signature verification and every claim check — the
      # `alg`, `aud`, `azp`, `exp` and `nonce` rules where an authentication bug is an
      # account takeover rather than a wrong answer. `docs/design/identity.md`
      # § Authentication says a login provisions a user on the spot, so this is the code
      # path that decides who exists. It takes its HTTP client from configuration, which
      # is what lets the tests drive a whole flow against a fake issuer.
      {:assent, "~> 0.3"},
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
      # Drives headless Chromium through chromedriver for `bin/look` and the gate's one
      # browser test (`docs/design/look.md`). Test-only and never started with the
      # application: the tool starts it itself. It is the choice the open proposal and the
      # ticket's refinement made, over Playwright, for one language and no Node.
      {:wallaby, "~> 0.31", only: :test, runtime: false},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Server-side syntax highlighting for the repository's file view, and for the whole-file
      # view Changes is to draw (`ForgeWeb.Highlight`, docs/design/ui.md § The project's
      # repository). Tree-sitter behind a precompiled NIF, emitting classes rather than inline
      # colours, so the palette stays the design's `--syntax-*` tokens. `flake.nix` hands the release its NIF, because
      # `rustler_precompiled` downloads it at compile time and a Nix build has no network.
      {:lumis, "~> 0.10.8"},
      # Lumis ships no grammars; each `lumis_wasm_*` is one, compiled from WebAssembly on first
      # use. The languages a project file is likely to be, plus the ones injected inside
      # another: `markdown_inline` (inside markdown), `css` and `javascript` (inside HTML and
      # HEEx), `eex`/`heex` (inside Elixir sigils), `comment` (TODO/FIXME inside comments).
      {:lumis_wasm_elixir, "~> 0.26.10"},
      {:lumis_wasm_eex, "~> 0.26.2"},
      {:lumis_wasm_heex, "~> 0.26.5"},
      {:lumis_wasm_erlang, "~> 0.26.8"},
      {:lumis_wasm_javascript, "~> 0.26.6"},
      {:lumis_wasm_typescript, "~> 0.26.5"},
      {:lumis_wasm_tsx, "~> 0.26.5"},
      {:lumis_wasm_json, "~> 0.26.7"},
      {:lumis_wasm_yaml, "~> 0.26.5"},
      {:lumis_wasm_toml, "~> 0.26.4"},
      {:lumis_wasm_nix, "~> 0.26.2"},
      {:lumis_wasm_bash, "~> 0.26.8"},
      {:lumis_wasm_css, "~> 0.26.6"},
      {:lumis_wasm_html, "~> 0.26.6"},
      {:lumis_wasm_markdown, "~> 0.26.4"},
      {:lumis_wasm_markdown_inline, "~> 0.26.4"},
      {:lumis_wasm_rust, "~> 0.26.7"},
      {:lumis_wasm_python, "~> 0.26.7"},
      {:lumis_wasm_go, "~> 0.26.6"},
      {:lumis_wasm_sql, "~> 0.26.7"},
      {:lumis_wasm_diff, "~> 0.26.7"},
      {:lumis_wasm_dockerfile, "~> 0.26.5"},
      {:lumis_wasm_make, "~> 0.26.2"},
      {:lumis_wasm_xml, "~> 0.26.6"},
      {:lumis_wasm_comment, "~> 0.26.2"}
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
        # The gate's one browser test loads the app's script, and the built assets are an ignored
        # directory a fresh checkout does not have: without this the test fails on every machine
        # that has not built them (a fresh clone, a command machine, any ticket that never ran
        # `bin/look`), with "LiveView did not connect".
        "tailwind forge",
        "esbuild forge",
        "test --cover"
      ]
    ]
  end
end
