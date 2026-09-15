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
  """

  use Forge.DataCase, async: true

  import Forge.ForgeFixtures

  alias Forge.Git.{Token, Tokens}

  setup do
    project = project_fixture()

    %{
      project: project,
      job_a: job_fixture(%{ticket: ticket_fixture(%{project: project, branch: "ticket/1"})}),
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
end
