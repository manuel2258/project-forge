defmodule Forge.WorkersBackfillTest do
  @moduledoc """
  What `WorkersHaveOwners` does to a node that is already running — the upgrade path.

  Before it, every connected machine took any project's jobs; after it, a job runs only on a
  machine assigned to its project. The migration's claim is that on a node with one operator
  nothing visible changes, and a claim about a deploy is checked here against a database rolled
  back to before the migration, filled the way an old node would be, and migrated forward.

  Not sandboxed, for the reason `Forge.ReleaseMigrateTest` gives: the migrator runs from its own
  connection. So this takes the repo out of sandbox mode, deletes what it wrote, and puts the
  schema and the mode back.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Migrations, Release, Repo}

  @version 20_260_924_110_000

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    # What this test wrote, in an agent rather than the test's own process: `on_exit/1` runs after
    # that process is gone, and outside the sandbox nothing else takes the rows away.
    {:ok, written} = Agent.start(fn -> [] end)
    Process.put(:written, written)

    on_exit(fn ->
      ids = Agent.get(written, & &1)
      Agent.stop(written)

      # Forward before anything is deleted: a test that failed inside the migration left the
      # schema behind it, without the table the first delete names, and a cleanup that crashed
      # there would leave every row for the next file to trip over.
      Migrations.forget(@version)
      Release.migrate()

      for table <- ~w(project_workers workers worker_templates project_members projects users) do
        Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [ids])
      end

      Sandbox.mode(Repo, :manual)
    end)

    # An empty database outside the sandbox, or the node-admin count below means nothing.
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM users")
    :ok
  end

  defp id do
    id = Ecto.UUID.generate()
    Agent.update(Process.get(:written), &[Ecto.UUID.dump!(id) | &1])
    id
  end

  defp user(node_admin) do
    uid = id()

    Repo.query!(
      "INSERT INTO users (id, email, node_admin, approved_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, NOW(), NOW(), NOW())",
      [Ecto.UUID.dump!(uid), "u#{System.unique_integer([:positive])}@example.com", node_admin]
    )

    uid
  end

  defp project(members) do
    pid = id()

    Repo.query!(
      "INSERT INTO projects (id, name, repo_path, inserted_at, updated_at) " <>
        "VALUES ($1, $2, '/nowhere.git', NOW(), NOW())",
      [Ecto.UUID.dump!(pid), "p#{System.unique_integer([:positive])}"]
    )

    for uid <- members do
      Repo.query!(
        "INSERT INTO project_members (id, project_id, user_id, role, inserted_at, updated_at) " <>
          "VALUES ($1, $2, $3, 'admin', NOW(), NOW())",
        [Ecto.UUID.dump!(id()), Ecto.UUID.dump!(pid), Ecto.UUID.dump!(uid)]
      )
    end

    pid
  end

  defp template(owner) do
    tid = id()

    Repo.query!(
      "INSERT INTO worker_templates (id, user_id, name, provider, memory, cores, max_workers, " <>
        "inserted_at, updated_at) VALUES ($1, $2, 'agents', 'fake', 8000, 2, 1, NOW(), NOW())",
      [Ecto.UUID.dump!(tid), Ecto.UUID.dump!(owner)]
    )

    tid
  end

  defp worker(attrs) do
    wid = id()
    template = attrs[:template] && Ecto.UUID.dump!(attrs[:template])

    Repo.query!(
      "INSERT INTO workers (id, provider, status, managed, template_id, inserted_at, updated_at) " <>
        "VALUES ($1, 'fake', $2, $3, $4, NOW(), NOW())",
      [Ecto.UUID.dump!(wid), attrs[:status] || "ready", attrs[:managed] || false, template]
    )

    wid
  end

  defp owner_of(wid) do
    %{rows: [[owner]]} =
      Repo.query!("SELECT user_id FROM workers WHERE id = $1", [Ecto.UUID.dump!(wid)])

    owner && Ecto.UUID.load!(owner)
  end

  defp served_by(wid) do
    %{rows: rows} =
      Repo.query!("SELECT project_id FROM project_workers WHERE worker_id = $1", [
        Ecto.UUID.dump!(wid)
      ])

    rows |> Enum.map(fn [pid] -> Ecto.UUID.load!(pid) end) |> Enum.sort()
  end

  defp migrate, do: Migrations.up_to(@version)

  test "one operator: every machine is theirs, and serves every project they are in" do
    admin = user(true)
    colleague = user(false)
    theirs = project([admin])
    also_theirs = project([admin, colleague])
    not_theirs = project([colleague])

    permanent = worker(managed: false)
    gone = worker(managed: false, status: "destroyed")
    made = worker(managed: true, template: template(colleague))

    migrate()

    assert owner_of(permanent) == admin
    assert served_by(permanent) == Enum.sort([theirs, also_theirs])
    refute not_theirs in served_by(permanent)

    # A destroyed machine gets an owner, and nothing to serve: it will never take work again.
    assert owner_of(gone) == admin
    assert served_by(gone) == []

    # A machine made from a template is the template owner's, and serves through the template
    # rather than with rows of its own.
    assert owner_of(made) == colleague
    assert served_by(made) == []
  end

  # `Accounts.owner_for/1`'s rule: guessing whose machine it is would be guessing whose money it
  # spends. Such a machine takes no work until someone says.
  test "more than one node admin: a machine with no template is given to nobody" do
    first = user(true)
    _second = user(true)
    project([first])
    permanent = worker(managed: false)

    migrate()

    assert owner_of(permanent) == nil
    assert served_by(permanent) == []
  end
end
