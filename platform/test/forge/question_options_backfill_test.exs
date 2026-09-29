defmodule Forge.QuestionOptionsBackfillTest do
  @moduledoc """
  What `QuestionOptionsCarryDetail` does to a node that is already running.

  Its claim is that a question recorded before options had details is still answerable, and that
  its form still starts on what the agent recommended: each old label becomes an option with no
  detail, in its order, and the old `default` becomes the recommended one. Checked against a
  database rolled back to before it, filled the way an old node's would be, and migrated forward —
  the pattern `Forge.WorkersBackfillTest` set, with the same reason for running outside the
  sandbox (`Forge.Migrations`). And back, because `down/0` claims to restore the old columns.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.Artifacts.Question
  alias Forge.{Migrations, Release, Repo}

  @version 20_260_928_100_000

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    {:ok, written} = Agent.start(fn -> %{} end)
    Process.put(:written, written)

    on_exit(fn ->
      rows = Agent.get(written, & &1)
      Agent.stop(written)

      # Forward before anything is deleted, so a test that failed with the schema rolled back
      # still leaves it current for the next file.
      Migrations.forget(@version)
      Release.migrate()

      # A version is append-only by trigger, whatever role asks; the rows this test made are
      # taken away with the trigger off, inside one transaction, so a failed delete puts it back.
      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE artifact_versions DISABLE TRIGGER artifact_versions_append_only")

        for table <- ~w(questions artifact_versions artifacts tickets projects) do
          Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [Map.get(rows, table, [])])
        end

        Repo.query!("ALTER TABLE artifact_versions ENABLE TRIGGER artifact_versions_append_only")
      end)

      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp insert(table, sql, params) do
    id = Ecto.UUID.generate()

    Agent.update(
      Process.get(:written),
      &Map.update(&1, table, [dump(id)], fn ids -> [dump(id) | ids] end)
    )

    Repo.query!(sql, [dump(id) | params])
    id
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  # A version to hang questions on, and everything it needs above it. The ticket is finished, so
  # nothing reading the queue node-wide in another file counts it.
  defp version do
    project =
      insert(
        "projects",
        "INSERT INTO projects (id, name, repo_path, inserted_at, updated_at) " <>
          "VALUES ($1, $2, '/nowhere.git', NOW(), NOW())",
        ["p#{System.unique_integer([:positive])}"]
      )

    ticket =
      insert(
        "tickets",
        "INSERT INTO tickets (id, project_id, number, title, base_commit, branch, workflow, " <>
          "workflow_commit, state, status, inserted_at, updated_at) " <>
          "VALUES ($1, $2, 1, 't', 'a', 'b', '{}', 'c', 'planning', 'done', NOW(), NOW())",
        [dump(project)]
      )

    artifact =
      insert(
        "artifacts",
        "INSERT INTO artifacts (id, ticket_id, name, kind, inserted_at, updated_at) " <>
          "VALUES ($1, $2, 'plan.md', 'document', NOW(), NOW())",
        [dump(ticket)]
      )

    insert(
      "artifact_versions",
      "INSERT INTO artifact_versions (id, artifact_id, version, author, content, content_hash, " <>
        "inserted_at) VALUES ($1, $2, 1, '{}', '', 'h', NOW())",
      [dump(artifact)]
    )
  end

  defp question(version, key, options, default) do
    insert(
      "questions",
      "INSERT INTO questions (id, artifact_version_id, key, text, options, \"default\", line, " <>
        "inserted_at) VALUES ($1, $2, $3, 't', $4, $5, 1, NOW())",
      [dump(version), key, options, default]
    )
  end

  test "each old label is an option with no detail, in order, and the default is recommended" do
    version = version()
    chose = question(version, "chose", ["local-file", "sqlite", "memory"], "sqlite")
    none = question(version, "none", ["a", "b"], nil)
    free = question(version, "free", [], nil)

    Migrations.up_to(@version)

    assert [
             %{label: "local-file", detail: nil, recommended: false},
             %{label: "sqlite", detail: nil, recommended: true},
             %{label: "memory", detail: nil, recommended: false}
           ] = Repo.get!(Question, chose).options

    assert [%{recommended: false}, %{recommended: false}] = Repo.get!(Question, none).options
    assert Repo.get!(Question, free).options == []

    # And back: the labels in their order, and the recommendation as the default again.
    Migrations.back_to(@version)

    assert %{rows: [[["local-file", "sqlite", "memory"], "sqlite"]]} =
             Repo.query!(~s(SELECT options, "default" FROM questions WHERE id = $1), [dump(chose)])

    assert %{rows: [[["a", "b"], nil]]} =
             Repo.query!(~s(SELECT options, "default" FROM questions WHERE id = $1), [dump(none)])

    assert %{rows: [[[], nil]]} =
             Repo.query!(~s(SELECT options, "default" FROM questions WHERE id = $1), [dump(free)])
  end
end
