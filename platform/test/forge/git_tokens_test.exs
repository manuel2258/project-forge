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
    {:ok, secret, row} = Tokens.issue(project, job_id: job.id, ref: ref)
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

  # `docs/design/archive.md` § The door and its grant: the archive is opened by a job's token and
  # by no other, and by one that is still alive.
  describe "authorise_job" do
    test "accepts a live token a job holds", %{project: project, job_a: job} do
      {:ok, secret, row} = Tokens.issue(project, job_id: job.id)

      assert {:ok, %Token{id: id, job_id: job_id}} = Tokens.authorise_job(secret)
      assert id == row.id
      assert job_id == job.id
    end

    test "refuses an operator's token, which holds no job", %{project: project} do
      {:ok, secret, _row} = Tokens.issue(project, name: "operator")

      assert Tokens.authorise_job(secret) == :error
    end

    test "refuses a revoked token, and an expired one", %{project: project, job_a: job} do
      {:ok, revoked, _row} = Tokens.issue(project, job_id: job.id)
      Tokens.revoke_for_job(job.id)
      assert Tokens.authorise_job(revoked) == :error

      {:ok, expired, row} = Tokens.issue(project, job_id: job.id)
      past = DateTime.add(DateTime.utc_now(:second), -1, :second)
      Repo.update!(Ecto.Changeset.change(row, expires_at: past))
      assert Tokens.authorise_job(expired) == :error
    end

    test "refuses what is not a token, identically", %{project: project, job_a: job} do
      {:ok, _secret, _row} = Tokens.issue(project, job_id: job.id)

      for secret <- [nil, "", "not base64 !!", Base.url_encode64("short", padding: false), 7] do
        assert Tokens.authorise_job(secret) == :error
      end
    end
  end

  describe "what may be minted" do
    test "an operator may be given the project's default branch", %{project: project} do
      assert {:ok, _secret, token} =
               Tokens.issue(project, name: "t", ref: Tokens.default_ref(project))

      assert token.ref == "refs/heads/main"
      assert token.git_access == :branch
    end

    test "a job is never given it, however it is asked for", %{project: project, job_a: job} do
      assert {:error, changeset} =
               Tokens.issue(project,
                 job_id: job.id,
                 ref: Tokens.default_ref(project)
               )

      assert "a job is never given the default branch" in errors_on(changeset).ref
    end

    test "the engine's own call for a job asks for the ticket's branch", context do
      %{project: project, job_a: job, ticket_a: ticket} = context

      {:ok, _secret, token} = Tokens.issue_for_job(job, ticket, project)

      assert token.ref == "refs/heads/" <> ticket.branch
      refute token.ref == Tokens.default_ref(project)
    end

    # A conversation pushes after every turn for up to a day. A token of the fixed ninety
    # minutes refused every push after that, and each turn's commit was lost with a warning.
    # (A workflow job's hour sits inside the fixed lifetime either way, so only a chat can tell
    # the job's clock from the constant.)
    test "a job's token lives as long as the job may", %{project: project} do
      chat = chat_fixture(%{project: project})
      {:ok, _secret, token} = Tokens.issue_for_job(chat, nil, project)

      # Against the literal day, not `Forge.Jobs.wall_clock_ms/1`: a test that asks the function
      # it depends on passes however short that function makes a conversation's clock.
      lifetime = DateTime.diff(token.expires_at, DateTime.utc_now(:second))
      assert lifetime > 24 * 3600
    end

    # A lost worker's job goes back in the queue and its next run mints its own credential. The
    # old one lives the job's whole wall clock, so a machine that was only partitioned could
    # otherwise go on pushing after the job was handed to somebody else.
    test "requeueing a job revokes its credential", context do
      %{project: project, ticket_a: ticket, job_a: job} = context
      {:ok, secret, _token} = Tokens.issue_for_job(job, ticket, project)
      assert {:ok, _token} = Tokens.authorise(secret, project, :read)

      assert {:ok, _job} = Forge.Jobs.requeue(job.id, :worker_lost)
      assert Tokens.authorise(secret, project, :read) == :error
    end

    # The same holds wherever a run stops without the job ending: the next run mints its own.
    test "a job hibernated, or recovered on boot, loses its credential too", context do
      %{project: project, ticket_a: ticket, job_a: job} = context
      {:ok, hibernating, _token} = Tokens.issue_for_job(job, ticket, project)

      assert {:ok, _job} = Forge.Jobs.hibernate(job.id, nil, "parked")
      assert Tokens.authorise(hibernating, project, :read) == :error

      other = ticket_fixture(%{project: project, branch: "ticket/3"})
      running = job_fixture(%{ticket: other, status: :running})
      {:ok, recovering, _token} = Tokens.issue_for_job(running, other, project)

      assert Forge.Jobs.recover() >= 1
      assert Tokens.authorise(recovering, project, :read) == :error
    end

    test "a branch is privileged only where it is the default", %{project: project} do
      trunk = project_fixture(%{default_branch: "trunk"})

      # `main` is nothing special to a project whose default branch is `trunk`: it is neither the
      # default nor a ticket's nor a chat's, so it cannot be minted at all. The hook reads
      # `forge.defaultBranch` from the repository for the same reason.
      assert {:error, changeset} =
               Tokens.issue(trunk, name: "t", ref: "refs/heads/main")

      assert [message] = errors_on(changeset).ref
      assert message =~ "refs/heads/trunk"

      assert {:ok, _secret, token} =
               Tokens.issue(trunk, name: "t", ref: "refs/heads/trunk")

      assert token.ref == "refs/heads/trunk"

      # And the other way round, so the pair says the rule rather than one example of it.
      assert {:error, _changeset} = Tokens.issue(project, name: "t", ref: "refs/heads/trunk")
    end

    test "a ticket's and a chat's are the only other shapes", %{project: project} do
      assert {:ok, _secret, _token} =
               Tokens.issue(project, name: "t", ref: "refs/heads/ticket/7")

      id = Ecto.UUID.generate()

      assert {:ok, _secret, _token} =
               Tokens.issue(project, name: "t", ref: "refs/heads/chat/#{id}")

      assert {:error, changeset} = Tokens.issue(project, name: "t", ref: "refs/heads/wildcat")
      assert errors_on(changeset).ref != []
    end
  end
end
