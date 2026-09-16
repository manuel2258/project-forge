defmodule Forge.GitTokensTest do
  @moduledoc """
  The scope of a revocation.

  `Forge.Jobs` revokes a job's git credential the moment the job ends, which is the whole reason
  a credential is issued per job (`docs/design/git-hosting.md`). The blast radius of that call is
  therefore a security property: it has to reach every token of *that* job and no token of any
  other. A node runs many jobs at once, so "revoke everything unrevoked" would log one machine
  out of the git endpoint mid-push every time any other machine finished.

  `ForgeWeb.GitHttpTest` proves a revoked token is refused; nothing there ever has two jobs'
  credentials alive at the same time, which is the only arrangement in which the scope of the
  `where` clause is visible at all.

  § What may be minted is the other half: `Forge.Git.Token` is one of the two enforcement points
  behind the branch discipline — what may exist at all — and `priv/git-hooks/pre-receive`,
  which `ForgeWeb.GitHttpTest` drives, is the other.
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Git.{Token, Tokens}

  setup do
    project = project_fixture()
    ticket_a = ticket_fixture(%{project: project, branch: "ticket/1"})

    %{
      project: project,
      ticket_a: ticket_a,
      job_a: job_fixture(%{ticket: ticket_a}),
      job_b: job_fixture(%{ticket: ticket_fixture(%{project: project, branch: "ticket/2"})})
    }
  end

  defp issue!(project, job, ref) do
    {:ok, secret, row} = Tokens.issue(project, job_id: job.id, ref: ref, write: true)
    {secret, row}
  end

  test "revoking one job's credentials leaves another job's alone", context do
    %{project: project, job_a: job_a, job_b: job_b} = context

    {a_secret, a_row} = issue!(project, job_a, "refs/heads/ticket/1")
    {b_secret, b_row} = issue!(project, job_b, "refs/heads/ticket/2")

    assert Tokens.revoke_for_job(job_a.id) == 1

    # The one that ended cannot write any more...
    assert Tokens.authorise(a_secret, project, :write) == :error
    assert Repo.get!(Token, a_row.id).revoked_at

    # ...and the one still running is untouched, both as a row and as a credential. The second
    # of these is the one an operator would feel: a push refused halfway through a job.
    assert {:ok, %Token{id: id}} = Tokens.authorise(b_secret, project, :write)
    assert id == b_row.id
    refute Repo.get!(Token, b_row.id).revoked_at
  end

  test "a job with several credentials loses all of them, and only them", context do
    %{project: project, job_a: job_a, job_b: job_b} = context

    # A read credential and a write one, as a job that clones and then pushes holds.
    {:ok, _read, _read_row} = Tokens.issue(project, job_id: job_a.id)
    {_secret, _row} = issue!(project, job_a, "refs/heads/ticket/1")
    {b_secret, _row} = issue!(project, job_b, "refs/heads/ticket/2")

    assert Tokens.revoke_for_job(job_a.id) == 2
    assert {:ok, _token} = Tokens.authorise(b_secret, project, :write)
  end

  test "an already-revoked credential is not stamped a second time", context do
    %{project: project, job_a: job_a} = context
    {_secret, row} = issue!(project, job_a, "refs/heads/ticket/1")

    # Revoked an hour ago: `revoked_at` is the audit trail's record of *when* the credential
    # stopped working, so a later sweep that re-stamps it rewrites history.
    then = DateTime.add(DateTime.utc_now(:second), -3600, :second)
    Repo.update!(Ecto.Changeset.change(row, revoked_at: then))

    assert Tokens.revoke_for_job(job_a.id) == 0
    assert Repo.get!(Token, row.id).revoked_at == then
  end

  describe "what may be minted" do
    test "an operator may be given the project's default branch", %{project: project} do
      assert {:ok, _secret, token} =
               Tokens.issue(project, ref: Tokens.default_ref(project), write: true)

      assert token.ref == "refs/heads/main"
      assert token.write
    end

    test "a job is never given it, however it is asked for", %{project: project, job_a: job} do
      assert {:error, changeset} =
               Tokens.issue(project,
                 job_id: job.id,
                 ref: Tokens.default_ref(project),
                 write: true
               )

      assert "a job is never given the default branch" in errors_on(changeset).ref
    end

    test "the engine's own call for a job asks for the ticket's branch", context do
      %{project: project, job_a: job, ticket_a: ticket} = context

      {:ok, _secret, token} = Tokens.issue_for_job(job, ticket, project)

      assert token.ref == "refs/heads/" <> ticket.branch
      refute token.ref == Tokens.default_ref(project)
    end

    test "a branch is privileged only where it is the default", %{project: project} do
      trunk = project_fixture(%{default_branch: "trunk"})

      # `main` is nothing special to a project whose default branch is `trunk`: it is neither the
      # default nor a ticket's nor a chat's, so it cannot be minted at all. The hook reads
      # `forge.defaultBranch` from the repository for the same reason.
      assert {:error, changeset} =
               Tokens.issue(trunk, ref: "refs/heads/main", write: true)

      assert [message] = errors_on(changeset).ref
      assert message =~ "refs/heads/trunk"

      assert {:ok, _secret, token} =
               Tokens.issue(trunk, ref: "refs/heads/trunk", write: true)

      assert token.ref == "refs/heads/trunk"

      # And the other way round, so the pair says the rule rather than one example of it.
      assert {:error, _changeset} = Tokens.issue(project, ref: "refs/heads/trunk", write: true)
    end

    test "a ticket's and a chat's are the only other shapes", %{project: project} do
      assert {:ok, _secret, _token} =
               Tokens.issue(project, ref: "refs/heads/ticket/7", write: true)

      id = Ecto.UUID.generate()

      assert {:ok, _secret, _token} =
               Tokens.issue(project, ref: "refs/heads/chat/#{id}", write: true)

      assert {:error, changeset} = Tokens.issue(project, ref: "refs/heads/wildcat", write: true)
      assert errors_on(changeset).ref != []
    end
  end
end
