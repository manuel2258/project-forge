defmodule Forge.IntegratingJobTest do
  @moduledoc """
  The job of a merging state's `on_conflict` target, as the platform hands it out: the default
  branch named in its assignment, what conflicted and what landed in its spec, a protocol a worker
  needs to run it, and a token that reads the default branch and still writes nothing but the
  ticket's (`docs/design/job-prompt.md` § Integrating the default branch, `git-hosting.md` § The
  job's own git).
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Git, Jobs, Operator, Tickets}
  alias Forge.Git.{Tokens, Url}

  setup do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => conflict_workflow(:b),
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "integrating#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)
    {:ok, ticket} = Tickets.admit(project, %{title: "Settings", body: "do it"}, {:user, user.id})

    sha = commit_over_http(project, ticket.branch, "README.md", "the branch's version")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{blob_uri: "git:" <> sha})

    main = commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "Merge ticket/10: Home")

    {:ok, ticket} =
      ticket
      |> Ecto.Changeset.change(
        state: "review_ready",
        pending_transition: %{
          "from" => "review_ready",
          "to" => "merged",
          "outcome" => nil,
          "approve" => ["changeset"]
        }
      )
      |> Repo.update!()
      |> Operator.decide(user, :approved, nil)

    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "integrating"))

    %{project: project, bare: bare, ticket: ticket, job: job, main: main, sha: sha}
  end

  test "is assigned the default branch, what conflicted and what landed", context do
    %{project: project, ticket: ticket, job: job, main: main, sha: sha} = context
    {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

    assignment = Jobs.assignment(job, ticket, project, token)

    assert assignment["git"]["default_branch"] == "main"

    assert %{
             "default_branch" => "main",
             "head" => ^main,
             "base" => base,
             "paths" => ["README.md"],
             "changeset" => ^sha,
             "merges" => [%{"sha" => ^main, "subject" => "Merge ticket/10: Home"}],
             "more" => 0
           } = assignment["spec"]["integration"]

    assert base == ticket.base_commit

    # Only the branch's name is the stored spec's: the rest is read when it runs.
    assert Jobs.spec(job).integration == %{"default_branch" => "main"}
  end

  # Twenty by name and the rest counted: a ticket that sat for a busy month is not handed a
  # manifest that is mostly a log.
  test "is told twenty of the merges that landed, and how many more", context do
    %{project: project, bare: bare, ticket: ticket, job: job} = context
    work = Path.join(tmp_dir("landed"), "work")
    {_out, 0} = job_git(Path.dirname(work), ["clone", "-q", "--branch", "main", bare, work])

    for n <- 1..21 do
      File.write!(Path.join(work, "landed-#{n}.txt"), "#{n}\n")
      {_out, 0} = job_git(work, ["add", "."])
      {_out, 0} = job_git(work, ["commit", "-qm", "Merge ticket/#{100 + n}"])
    end

    {_out, 0} =
      System.cmd("git", ["push", "-q", "origin", "HEAD:refs/heads/main"],
        cd: work,
        env: [{"FORGE_INTERNAL", "1"}],
        stderr_to_stdout: true
      )

    {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)
    integration = Jobs.assignment(job, ticket, project, token)["spec"]["integration"]

    assert length(integration["merges"]) == 20
    assert hd(integration["merges"])["subject"] == "Merge ticket/121"
    assert integration["more"] == 2
  end

  # The default branch's own line — one entry a merge — and not each commit a merge brought in.
  test "is told the default branch's merges, not what each brought in", context do
    %{project: project, bare: bare, ticket: ticket, job: job, main: main} = context
    work = Path.join(tmp_dir("first-parent"), "work")
    {_out, 0} = job_git(Path.dirname(work), ["clone", "-q", "--branch", "main", bare, work])
    {_out, 0} = job_git(work, ["checkout", "-q", "-b", "side"])
    File.write!(Path.join(work, "side.txt"), "a ticket's own commit\n")
    {_out, 0} = job_git(work, ["add", "."])
    {_out, 0} = job_git(work, ["commit", "-qm", "a ticket's own commit"])
    {_out, 0} = job_git(work, ["checkout", "-q", "main"])
    {_out, 0} = job_git(work, ["merge", "-q", "--no-ff", "-m", "Merge ticket/11: Side", "side"])

    {_out, 0} =
      System.cmd("git", ["push", "-q", "origin", "HEAD:refs/heads/main"],
        cd: work,
        env: [{"FORGE_INTERNAL", "1"}],
        stderr_to_stdout: true
      )

    {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)
    integration = Jobs.assignment(job, ticket, project, token)["spec"]["integration"]

    assert ["Merge ticket/11: Side", "Merge ticket/10: Home"] ==
             Enum.map(integration["merges"], & &1["subject"])

    assert List.last(integration["merges"])["sha"] == main
  end

  test "needs a worker that knows how to keep the merge", %{ticket: ticket, job: job} do
    assert Jobs.protocol(job) == 5

    [implementing] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "implementing"))
    assert Jobs.protocol(implementing) == 3
  end

  test "any other job is given no default branch", context do
    %{project: project, ticket: ticket} = context
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "implementing"))
    {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

    assignment = Jobs.assignment(job, ticket, project, token)

    refute Map.has_key?(assignment["git"], "default_branch")
    assert assignment["spec"]["integration"] == nil
  end

  # The kind that is neither: a command reads a commit and merges nothing, so it is told no
  # default branch either. Without a case for it, the clause that refuses one was only ever
  # reached by a workflow job without an integration, which lands on the first clause.
  test "a command is given no default branch", context do
    %{project: project, ticket: ticket, job: job} = context

    # This job's own spec, integration and all: the clause dispatches on the kind, and a command
    # that still carried an integration is the sharpest version of the question.
    command = %Forge.Jobs.Job{job | kind: :command}
    {:ok, token, _row} = Tokens.issue_for_job(command, ticket, project)

    assignment = Jobs.assignment(command, ticket, project, token)

    refute Map.has_key?(assignment["git"], "default_branch")
  end

  # Read, yes — a job's token has always read the whole project. Write, still only its own branch:
  # `pre-receive` refuses the default branch from it as from any job.
  test "its token reads the default branch and cannot write it", context do
    %{project: project, bare: bare, ticket: ticket, job: job, main: main} = context
    {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)
    url = Url.with_token(project, token)
    work = Path.join(tmp_dir("integrating"), "clone")

    {_out, 0} = job_git(Path.dirname(work), ["clone", "-q", "--branch", ticket.branch, url, work])
    {_out, 0} = job_git(work, ["fetch", "-q", url, "+refs/heads/main:refs/remotes/origin/main"])
    {_out, 1} = job_git(work, ["merge", "-q", "origin/main"])
    File.write!(Path.join(work, "README.md"), "both\n")
    {_out, 0} = job_git(work, ["commit", "-qam", "merge main"])

    assert {out, code} = job_git(work, ["push", "-q", url, "HEAD:refs/heads/main"])
    assert code != 0
    assert out =~ "main"
    assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")

    assert {_out, 0} = job_git(work, ["push", "-q", url, "HEAD:refs/heads/" <> ticket.branch])
  end
end
