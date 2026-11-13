defmodule Mix.Tasks.Forge.Look do
  @shortdoc "Open the platform in headless Chromium and run steps (use bin/look)"

  @moduledoc """
  `bin/look --setup NAME [--as USER] [--timeout S] < steps`: build the setup into a throwaway
  database, start the app on a port of its own, and run the steps from standard input in a
  browser (`docs/design/look.md`), logged in as `USER` or, without `--as`, logged out — the
  sign-in screens. Use `bin/look`, which first puts the run in a network
  namespace and starts a postgres of its own; this task is the part inside.

  Exit 0 when every step passed, 1 when a step failed or the invocation was wrong, 2 when the
  machine could not run the tool.
  """

  use Mix.Task

  alias Forge.Look

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [setup: :string, as: :string, timeout: :integer])

    halt(execute(opts, IO.read(:stdio, :eof)))
  end

  defp execute(opts, source) do
    with {:ok, setup} <- Look.Setups.fetch(opts[:setup] || ""),
         {:ok, steps} <- steps(source) do
      tmp = Path.join(System.tmp_dir!(), "forge-look-#{System.unique_integer([:positive])}")
      token = Look.Guard.generate()
      Logger.configure(level: :warning)
      configure(tmp, token)
      migrate()
      {:ok, _} = Application.ensure_all_started(:forge)
      Ecto.Adapters.SQL.Sandbox.start_owner!(Forge.Repo, shared: true)
      built = setup.build()

      # The run's own data directory and store go with it, whatever the steps did.
      try do
        run_as(steps, built, token, opts)
      after
        File.rm_rf(tmp)
      end
    else
      {:error, %{n: n, text: text, reason: reason}} ->
        IO.puts(:stderr, "FAILED step #{n}: #{text}\n  #{reason}")
        1

      {:error, reason} ->
        mistake(reason)
    end
  end

  defp run_as(steps, built, token, opts) do
    case opts[:as] && Map.fetch(built.users, opts[:as]) do
      nil ->
        drive(steps, built, nil, token, opts)

      {:ok, user} ->
        drive(steps, built, user, token, opts)

      :error ->
        mistake(
          "no user #{inspect(opts[:as])} in the setup; it has: #{built.users |> Map.keys() |> Enum.join(", ")}"
        )
    end
  end

  defp steps(source) do
    with {:ok, steps} <- Look.Steps.parse(source),
         true <- steps != [] or {:error, "no steps on standard input"} do
      {:ok, steps}
    end
  end

  # The data directory and the store are this run's own; the endpoint takes any free port on the
  # loopback and the URL host the browser uses, or LiveView's origin check refuses the socket.
  defp configure(tmp, token) do
    jobs = Application.get_env(:forge, Forge.Jobs, [])
    Application.put_env(:forge, Forge.Jobs, Keyword.put(jobs, :data_dir, Path.join(tmp, "jobs")))
    Application.put_env(:forge, Forge.Storage, dir: Path.join(tmp, "store"))

    endpoint = Application.get_env(:forge, ForgeWeb.Endpoint, [])

    Application.put_env(
      :forge,
      ForgeWeb.Endpoint,
      endpoint
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: 0)
      |> Keyword.put(:url, host: "127.0.0.1")
    )

    Look.Guard.put_token(token)
  end

  defp migrate do
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
  end

  defp drive(steps, built, user, token, opts) do
    login_token = user && elem(Forge.AccountsFixtures.generate_user_magic_link_token(user), 0)
    {:ok, {_ip, port}} = ForgeWeb.Endpoint.server_info(:http)

    case Look.run(steps,
           base_url: "http://127.0.0.1:#{port}",
           token: token,
           login_token: login_token,
           paths: built.paths,
           wait: (opts[:timeout] || 5) * 1000
         ) do
      :ok -> 0
      {:failed, _, _, _} -> 1
      {:could_not_run, reason} -> could_not(reason)
    end
  end

  # A setup, a user or a step list the caller got wrong is the caller's to fix: exit 1, like a
  # failed step, and not 2, which is the machine's and excuses an implementer from pictures.
  defp mistake(reason) do
    IO.puts(:stderr, "FAILED: #{reason}")
    1
  end

  defp could_not(reason) do
    IO.puts(:stderr, "could not run: #{reason}")
    2
  end

  defp halt(status), do: System.halt(status)
end
