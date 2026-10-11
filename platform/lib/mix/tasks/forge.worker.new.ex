defmodule Mix.Tasks.Forge.Worker.New do
  @shortdoc "Mints a worker's credentials: mix forge.worker.new [PROJECT] [--owner EMAIL] [--out FILE]"

  @moduledoc """
  Creates a worker row and prints what a machine needs to become that worker, as shell
  assignments. The measurement harness boots a machine by hand with these (`bin/measure m4`);
  so does anyone debugging an image.

      eval "$(mix forge.worker.new demo)"

  With a PROJECT whose seed has been published, it also prints the seed's key and a token to
  fetch it with, because M4 times that fetch as a phase of the cold start.

  The worker token is returned once and only its hash is kept, exactly as it is when the provider
  driver asks for one. Nothing is created on any provider: the row exists and the machine does
  not, and it is up to whoever ran this to make one. What it prints is `Forge.Workers.mint/2`'s,
  the same as *New machine* on `/workers` shows a person minting their own
  (`docs/design/identity.md` § Minting a permanent machine).

  **No agent credential is printed**, because a machine holds none: each job brings its own in its
  assignment (`docs/design/credentials.md`). The output is still a secret — the worker token is in
  it — so pipe it somewhere with a sane umask, not into a shell history.

  **The machine has an owner**, `--owner EMAIL` or the node's only node admin, and it takes a
  project's jobs only once its owner has assigned it to that project (`docs/design/identity.md`
  § Workers). With a PROJECT, the owner assigns it to that one here, which is refused unless they
  are a member; otherwise it takes no work until they assign it on `/workers`.

  **The row is unmanaged, and so it is permanent.** Neither sweep will destroy it — not the idle
  period, and not the unreachable timeout, which re-queues its jobs and leaves the row so the
  machine can rejoin. That is what makes a long-lived worker possible, and it is also the catch:
  a row minted here and never used sits there until somebody removes it. It counts against no
  ceiling — `max_workers` is a template's, and this row has none — so nothing stops them piling
  up. `mix forge.worker.list` shows them.
  """

  use Mix.Task

  alias Forge.{Accounts, CLI, Projects, Storage, Workers}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [out: :string, owner: :string])

    case positional do
      [] -> mint(nil, opts)
      [project] -> mint(project, opts)
      _other -> CLI.fail("usage: mix forge.worker.new [PROJECT] [--out FILE]")
    end
  end

  defp mint(name, opts) do
    CLI.boot()

    project = name && (Projects.by_name(name) || CLI.fail("unknown project #{name}"))
    owner = owner(Keyword.get(opts, :owner))

    # Unmanaged, always, and the membership checked before the row exists, so a refusal leaves
    # nothing behind to retire; see docs/design/worker-tier.md § Managed and unmanaged.
    case Workers.mint(owner, project && project.id) do
      {:ok, _worker, env} ->
        emit(Enum.join([env | seed(project)], "\n"), Keyword.get(opts, :out))

      {:error, :not_a_member} ->
        CLI.fail("#{owner.email} is not a member of #{project.name}, so cannot assign it")

      {:error, standing} when standing in [:not_approved, :suspended] ->
        CLI.fail("#{owner.email} is #{standing_word(standing)}, so cannot own a machine")

      {:error, changeset} ->
        CLI.fail(inspect(changeset.errors))
    end
  end

  defp standing_word(:not_approved), do: "not approved"
  defp standing_word(:suspended), do: "suspended"

  # The seed and a token to fetch it with, for the measurement harness, which fetches it itself and
  # times that as a phase of the cold start (`measure/lib/m4.sh`). The worker reads neither and the
  # token lasts minutes, so they are this command's and not part of what a machine is minted with.
  defp seed(%{seed_id: seed_id, name: name}) when is_binary(seed_id) do
    key = Storage.Key.seed(name, seed_id)
    ["FORGE_SEED_KEY=#{key}", "FORGE_SEED_TOKEN=#{Storage.Token.sign(:get, key)}"]
  end

  defp seed(_project), do: []

  # Whose machine this is. The same resolution `register_project/2` uses: a named account, or the
  # node's only node admin — and never a guess between several.
  defp owner(email) do
    case Accounts.owner_for(email) do
      {:ok, user} -> user
      {:error, :unknown_user} -> CLI.fail("unknown user #{email}")
      {:error, :no_owner} -> CLI.fail("no node admin exists to own it; pass --owner EMAIL")
      {:error, :ambiguous_owner} -> CLI.fail("more than one node admin: pass --owner EMAIL")
    end
  end

  # 0600 before anything is written to it: the file carries the worker token, and a umask that
  # would have made it readable is not the operator's mistake to discover later.
  defp emit(env, nil), do: Mix.shell().info(env)

  defp emit(env, path) do
    File.write!(path, env <> "\n")
    File.chmod!(path, 0o600)

    Mix.shell().info("wrote #{path} (mode 0600); it holds this machine's token")
  end
end
