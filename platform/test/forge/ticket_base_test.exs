defmodule Forge.TicketBaseTest do
  @moduledoc """
  The base a ticket's changeset is diffed against follows an integration: once the branch has
  merged the default branch, the base moves to where they last met, so the ticket's diff stops
  carrying every other ticket's work (`docs/design/workflow-grammar-v1.md` § Merging).
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Events, Git, Jobs, Operator, Tickets}
  alias ForgeCore.Job.Result

  setup do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => conflict_workflow(:reviewed),
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "base#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)
    {:ok, ticket} = Tickets.admit(project, %{title: "Timer", body: "do it"}, {:user, user.id})

    %{project: project, bare: bare, user: user, ticket: ticket}
  end

  test "moves to the default branch's head an integration merged", context do
    %{project: project, bare: bare, user: user, ticket: ticket} = context
    base = ticket.base_commit
    sha = commit_over_http(project, ticket.branch, "README.md", "the branch's")
    changeset!(ticket, sha)

    # Another ticket's work lands: one file in conflict, and one that is not this ticket's at all.
    main =
      commit_to(
        bare,
        "main",
        %{"README.md" => "the trunk's\n", "OTHER.md" => "theirs\n"},
        "other"
      )

    {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)
    assert ticket.state == "integrating"

    integrated = integrate!(bare, ticket)
    complete!(job_in(ticket, "integrating"))

    ticket = Tickets.get!(ticket.id)
    assert ticket.base_commit == main

    assert [%{payload: %{"from" => ^base, "to" => ^main}}] =
             ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "ticket.base_moved"))

    # The job the integration hands on to reads the ticket's own change, not the other ticket's.
    assert ticket.state == "reviewing"

    [changeset] =
      Enum.filter(Jobs.spec(job_in(ticket, "reviewing")).inputs, &(&1.name == "changeset"))

    assert changeset.version == integrated
    assert changeset.content =~ "README.md"
    refute changeset.content =~ "OTHER.md"
  end

  test "stays where it is for a result that merged nothing from the default branch", context do
    %{project: project, bare: bare, ticket: ticket} = context
    base = ticket.base_commit
    commit_to(bare, "main", %{"OTHER.md" => "theirs\n"}, "other")
    commit_over_http(project, ticket.branch, "README.md", "the branch's")

    complete!(job_in(ticket, "implementing"), "implementation.md")

    ticket = Tickets.get!(ticket.id)
    assert ticket.base_commit == base
    refute "ticket.base_moved" in (ticket.id |> Events.for_ticket() |> Enum.map(& &1.type))
    assert {:ok, _version} = Forge.Merge.changeset(ticket)
    assert Git.ancestor?(bare, base, ticket.base_commit)
  end

  # A branch rewritten onto an older commit of the default branch meets it further back than its
  # base; the base is where the ticket started, and does not follow it back.
  test "never moves back", context do
    %{project: project, bare: bare, user: user} = context
    commit_to(bare, "main", %{"OTHER.md" => "theirs\n"}, "other")
    {:ok, ticket} = Tickets.admit(project, %{title: "Later", body: ""}, {:user, user.id})
    base = ticket.base_commit
    work = Path.join(tmp_dir("rewind"), "work")
    {_out, 0} = git(Path.dirname(work), ["clone", "-q", "--branch", ticket.branch, bare, work])
    {_out, 0} = git(work, ["reset", "-q", "--hard", "HEAD^"])
    File.write!(Path.join(work, "REWOUND.md"), "on an older base\n")
    {_out, 0} = git(work, ["add", "."])
    {_out, 0} = git(work, ["commit", "-qm", "rewound"])
    {_out, 0} = git(work, ["push", "-q", "-f", "origin", "HEAD:refs/heads/" <> ticket.branch])

    complete!(job_in(ticket, "implementing"), "implementation.md")

    assert Tickets.get!(ticket.id).base_commit == base
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp job_in(ticket, state),
    do: ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == state)) |> List.last()

  # A job's result as its worker reports it: the branch already holds what it pushed.
  defp complete!(job, document \\ nil) do
    documents =
      if document,
        do: %{document => ForgeCore.Document.parse!("---\noutcome: done\n---\n# Done\n")},
        else: %{}

    {:ok, _job} =
      Jobs.complete(job.id, %Result{
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        documents: documents,
        harness: %{}
      })
  end
end
