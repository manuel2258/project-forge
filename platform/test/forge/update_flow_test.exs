defmodule Forge.UpdateFlowTest do
  @moduledoc """
  An update step: a state that brings the ticket's branch up to date with the default branch and
  takes its one edge out, with no job (`docs/design/workflow-grammar-v1.md` § Bringing the branch
  up to date). Its four results, what each records, where a conflict goes, the pin, the base, the
  race with someone pushing to the branch, and the places that must leave a running step alone.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, Tickets}
  alias Forge.Git.Tokens

  defp workflow(opts \\ []), do: update_workflow(opts)

  # `plain: true`: the workflow a ticket pinned before the step existed has, with no step in it.
  defp initial_workflow(plain: true) do
    """
    version: 1
    initial: implementing
    states:
      implementing:
        prompt: agents/implement.md
        produces: [implementation.md, changeset, commit-message]
        budget: { turns: 10, tokens: 200k }
      review_ready: {}
      merged:
        on_enter: merge
    transitions:
      - { from: implementing, to: review_ready }
      - { from: review_ready, to: merged, approve: [changeset] }
    limits:
      ticket_tokens: 5M
    """
  end

  defp initial_workflow(opts), do: workflow(opts)

  defp setup_project(context) do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => initial_workflow(Map.get(context, :workflow, [])),
        ".forge/agents/integrate.md" => "Merge the default branch in.\n",
        ".forge/agents/implement.md" => "Implement.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "update#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Practice timer", body: "do it"}, {:user, user.id})

    commit_message!(ticket)
    %{project: project, bare: bare, user: user, ticket: ticket}
  end

  setup context, do: setup_project(context)

  # The ticket's implementing job ends, and the engine takes the edge into the step, which runs.
  defp finish!(ticket, state \\ "implementing", outcome \\ "done") do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> Enum.filter(&(&1.state == state))
      |> List.last()
      |> Ecto.Changeset.change(status: :finished, outcome: :converged, declared_outcome: outcome)
      |> Repo.update!()

    {:ok, ticket} = Engine.after_job(Tickets.get!(ticket.id), job, outcome)
    ticket
  end

  # The job ends, and nothing else happens: the engine has not decided where the ticket goes.
  defp end_job!(ticket, state \\ "implementing") do
    ticket.id
    |> Jobs.for_ticket()
    |> Enum.filter(&(&1.state == state))
    |> List.last()
    |> Ecto.Changeset.change(
      status: :finished,
      outcome: :converged,
      declared_outcome: "done",
      started_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  defp visit(ticket), do: latest_payload(ticket, "ticket.branch_updated")
  defp head(bare, ticket), do: elem(Git.resolve(bare, "refs/heads/" <> ticket.branch), 1)

  defp own_commit!(%{project: project, ticket: ticket}, path \\ "feature.txt", text \\ "mine") do
    commit_over_http(project, ticket.branch, path, text)
  end

  describe "already current" do
    test "moves nothing, records nothing but the visit, and goes on", %{bare: bare} = context do
      %{ticket: ticket} = context
      before = head(bare, ticket)

      ticket = finish!(ticket)

      assert ticket.state == "review_ready"
      assert ticket.status == :active
      assert head(bare, ticket) == before
      assert Artifacts.versions(ticket.id, "changeset") == []

      assert %{
               "result" => "current",
               "state" => "refresh",
               "default_branch" => "main",
               "from" => ^before,
               "to" => ^before,
               "default" => ^before,
               "repin" => nil,
               "merges" => [],
               "retried" => false,
               "went" => "review_ready"
             } = visit(ticket)

      assert events_of(ticket, "ticket.base_moved") == []
      assert events_of(ticket, "ticket.repinned") == []

      # The engine's own visit and edge; no job, so no tokens.
      assert %{"from" => "refresh", "to" => "review_ready", "outcome" => "done"} =
               latest_payload(ticket, "transition.taken")

      assert [%{actor: %{"kind" => "system"}}] = events_of(ticket, "ticket.branch_updated")
      assert Jobs.for_ticket(ticket.id) |> Enum.map(& &1.state) == ["implementing"]
    end
  end

  describe "nothing of its own" do
    test "is moved forward to the default branch's head, with no merge commit", context do
      %{bare: bare, ticket: ticket} = context
      base = ticket.base_commit
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")

      ticket = finish!(ticket)

      assert head(bare, ticket) == main
      assert ticket.base_commit == main
      assert Artifacts.versions(ticket.id, "changeset") == []

      assert %{"result" => "forwarded", "from" => ^base, "to" => ^main, "default" => ^main} =
               visit(ticket)

      assert %{"from" => ^base, "to" => ^main} = latest_payload(ticket, "ticket.base_moved")
    end
  end

  describe "its own commits, and a clean merge" do
    test "the platform merges: two parents, its own author, a version, the base moved", context do
      %{bare: bare, ticket: ticket} = context
      own = own_commit!(context)
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")

      ticket = finish!(ticket)
      merged = head(bare, ticket)

      assert merged != own
      {:ok, parents} = Git.run(bare, ["log", "-1", "--format=%P", merged])
      assert String.split(parents) == [own, main]
      {:ok, who} = Git.run(bare, ["log", "-1", "--format=%an <%ae> / %cn <%ce>", merged])
      assert String.trim(who) == "forge <forge@localhost> / forge <forge@localhost>"
      {:ok, subject} = Git.run(bare, ["log", "-1", "--format=%s", merged])
      assert String.trim(subject) == "Merge main into #{ticket.branch}"

      # The version the step left, by the engine, and the base the diff is taken against.
      assert [%{version: 1, author: %{"kind" => "system"}} = version] =
               Artifacts.versions(ticket.id, "changeset")

      assert Artifacts.commit(version) == merged
      assert ticket.base_commit == main
      {:ok, names} = Git.run(bare, ["diff", "--name-only", "#{ticket.base_commit}..#{merged}"])
      assert String.split(names) == ["feature.txt"]

      assert %{"result" => "merged", "from" => ^own, "to" => ^merged, "default" => ^main} =
               visit(ticket)

      assert [%{"sha" => ^main, "subject" => "Merge ticket/9: Other"}] = visit(ticket)["merges"]
      assert ticket.state == "review_ready"
    end

    test "a merge a ticket made is said by its number, a conversation's by its id", context do
      %{bare: bare, ticket: ticket, project: project, user: user} = context
      five = admit_other!(project, user, "Five")
      other = commit_to(bare, "main", %{"a.txt" => "a\n"}, "Merge ticket/5: Five")
      merged!(five, other, user)

      chat = commit_to(bare, "main", %{"b.txt" => "b\n"}, "Merge chat: notes")

      {:ok, _} =
        Events.append("chat.merged", :system, %{
          project_id: project.id,
          payload: %{"chat" => "chat-1", "sha" => chat}
        })

      loose = commit_to(bare, "main", %{"c.txt" => "c\n"}, "no record of it")

      # A merge that landed nothing new (`already`) is not what the commit with that sha was.
      claimed = commit_to(bare, "main", %{"e.txt" => "e\n"}, "Merge ticket/8: Eight")
      eight = admit_other!(project, user, "Eight")

      {:ok, _} =
        Events.append("ticket.merged", {:user, user.id}, %{
          ticket_id: eight.id,
          project_id: project.id,
          payload: %{"sha" => claimed, "already" => true}
        })

      ticket = finish!(ticket)

      assert [
               %{"sha" => ^claimed} = fourth,
               %{"sha" => ^loose} = third,
               %{"sha" => ^chat, "chat" => "chat-1"},
               %{"sha" => ^other, "ticket" => number}
             ] = visit(ticket)["merges"]

      assert number == five.number
      refute Map.has_key?(fourth, "ticket")
      refute Map.has_key?(third, "ticket")
      refute Map.has_key?(third, "chat")
    end

    # Two projects whose repositories share history hold the same commit; what another project
    # recorded about it is not this project's, and its number would be drawn with this project's
    # own title for that number.
    test "a merge another project recorded for the same commit is not claimed", context do
      %{bare: bare, ticket: ticket, user: user} = context

      other_bare =
        seeded_repo(%{
          ".forge/workflow.yml" => workflow(),
          ".forge/agents/integrate.md" => "Merge the default branch in.\n",
          ".forge/agents/implement.md" => "Implement.\n"
        })

      {:ok, elsewhere} =
        register_owned!(%{
          name: "elsewhere#{System.unique_integer([:positive])}",
          repo_path: other_bare,
          default_branch: "main"
        })

      join!(elsewhere, user)
      theirs = admit_other!(elsewhere, user, "Theirs")

      sha = commit_to(bare, "main", %{"a.txt" => "a\n"}, "Merge ticket/5: Five")
      merged!(theirs, sha, user)

      {:ok, _} =
        Events.append("chat.merged", :system, %{
          project_id: elsewhere.id,
          payload: %{"chat" => "their-chat", "sha" => sha}
        })

      ticket = finish!(ticket)

      assert [%{"sha" => ^sha} = merge] = visit(ticket)["merges"]
      refute Map.has_key?(merge, "ticket")
      refute Map.has_key?(merge, "chat")
    end

    defp admit_other!(project, user, title) do
      {:ok, other} = Tickets.admit(project, %{title: title, body: "."}, {:user, user.id})
      other
    end

    defp merged!(ticket, sha, user) do
      {:ok, _} =
        Events.append("ticket.merged", {:user, user.id}, %{
          ticket_id: ticket.id,
          project_id: ticket.project_id,
          payload: %{"sha" => sha, "already" => false}
        })
    end

    # The commits a merge on the default branch brought in are not merges of the default branch's
    # own: only its first-parent line is listed.
    test "only the default branch's own line is listed, not what a merge there brought",
         context do
      %{bare: bare, ticket: ticket} = context
      base = head(bare, ticket)
      side = commit_beside(bare, base, "side.txt", "from a branch")
      tip = commit_to(bare, "main", %{"y.txt" => "y\n"}, "Merge ticket/6: Six")
      {:ok, tree} = Forge.Merge.merge_tree(bare, tip, side)

      {:ok, merge} =
        Forge.Merge.commit_tree(bare, tree, [tip, side], "Merge ticket/7: Seven", nil)

      {:ok, _} = Git.run(bare, ["update-ref", "refs/heads/main", merge])

      ticket = finish!(ticket)

      assert %{"merges" => merges, "more" => 0} = visit(ticket)
      assert Enum.map(merges, & &1["sha"]) == [merge, tip]
    end

    # A branch that already holds the default branch's head, past its base (a developer merged it
    # by hand), is *current*, and its base still moves up to it.
    test "a branch that already holds the default branch's head has its base moved", context do
      %{bare: bare, ticket: ticket} = context
      own = own_commit!(context)
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      {:ok, tree} = Forge.Merge.merge_tree(bare, own, main)
      {:ok, merged} = Forge.Merge.commit_tree(bare, tree, [own, main], "by hand", nil)
      {:ok, _} = Git.run(bare, ["update-ref", "refs/heads/#{ticket.branch}", merged])
      refute ticket.base_commit == main

      ticket = finish!(ticket)

      assert %{"result" => "current"} = visit(ticket)
      assert ticket.base_commit == main
      assert [%{payload: %{"to" => ^main}}] = events_of(ticket, "ticket.base_moved")
    end

    test "at most ten merges are listed, and the rest counted", %{bare: bare, ticket: ticket} do
      for n <- 1..12, do: commit_to(bare, "main", %{"n#{n}.txt" => "#{n}\n"}, "Merge ticket/#{n}")
      ticket = finish!(ticket)

      assert %{"merges" => merges, "more" => 2} = visit(ticket)
      assert length(merges) == 10
      assert hd(merges)["subject"] == "Merge ticket/12"
    end
  end

  describe "a conflict" do
    defp conflicting!(%{bare: bare} = context) do
      own = own_commit!(context, "README.md", "the branch's version")
      main = commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "Merge ticket/9")
      {own, main}
    end

    test "leaves the branch alone and goes to the state the step names", context do
      %{bare: bare, ticket: ticket} = context
      {own, main} = conflicting!(context)

      ticket = finish!(ticket)

      assert head(bare, ticket) == own
      assert ticket.state == "resolving"
      assert ticket.status == :active

      assert %{
               "result" => "conflicted",
               "paths" => ["README.md"],
               "from" => ^own,
               "default" => ^main,
               "went" => "resolving"
             } = visit(ticket)

      assert %{"from" => "refresh", "to" => "resolving", "outcome" => "merge_conflict"} =
               latest_payload(ticket, "transition.taken")

      # Not the merge's own conflict: the three-in-a-row bound reads that event alone.
      assert events_of(ticket, "ticket.merge_conflicted") == []
      assert events_of(ticket, "ticket.base_moved") == []
    end

    test "the job it makes is told what conflicted, by the update, and given the branch",
         context do
      %{project: project, ticket: ticket} = context
      {own, main} = conflicting!(context)
      ticket = finish!(ticket)
      [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "resolving"))
      {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

      assignment = Jobs.assignment(job, ticket, project, token)

      assert assignment["git"]["default_branch"] == "main"

      assert %{
               "default_branch" => "main",
               "cause" => "update",
               "head" => ^main,
               "paths" => ["README.md"]
             } = assignment["spec"]["integration"]

      assert assignment["spec"]["base"] == ticket.base_commit
      refute assignment["spec"]["base"] == own
    end

    test "what sent the job is read as the later of the step's and the merge's", context do
      %{project: project, ticket: ticket} = context

      # An older conflict of the merge's own, which the step's later one replaces.
      {:ok, _} =
        Events.append("ticket.merge_conflicted", :system, %{
          ticket_id: ticket.id,
          payload: %{"paths" => ["lib/old.ex"], "changeset" => String.duplicate("d", 40)}
        })

      {_own, _main} = conflicting!(context)
      ticket = finish!(ticket)
      [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "resolving"))
      {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

      assert %{"cause" => "update", "paths" => ["README.md"]} =
               Jobs.assignment(job, ticket, project, token)["spec"]["integration"]

      # A merge's own conflict, later: the job reads that one, with its paths and no `cause`.
      {:ok, _} =
        Events.append("ticket.merge_conflicted", :system, %{
          ticket_id: ticket.id,
          payload: %{"paths" => ["lib/other.ex"], "changeset" => String.duplicate("c", 40)}
        })

      integration = Jobs.assignment(job, ticket, project, token)["spec"]["integration"]
      assert integration["paths"] == ["lib/other.ex"]
      assert integration["cause"] == nil
    end

    @tag workflow: [conflict: false]
    test "with nowhere to go, sticks the ticket with the paths", context do
      %{bare: bare, ticket: ticket} = context
      {own, _main} = conflicting!(context)

      ticket = finish!(ticket)

      assert ticket.state == "refresh"
      assert ticket.status == :stuck
      assert head(bare, ticket) == own

      assert Engine.why_stuck(ticket) ==
               "bringing the branch up to date with main conflicted in README.md"
    end

    test "a long list of paths is cut when it is said", context do
      %{bare: bare, ticket: ticket} = context
      files = for n <- 1..5, into: %{}, do: {"f#{n}.txt", "main #{n}\n"}
      commit_to(bare, "main", files, "many")

      ticket = Tickets.get!(ticket.id)
      work = Path.join(tmp_dir("both"), "work")
      {_o, 0} = git(Path.dirname(work), ["clone", "-q", "--branch", ticket.branch, bare, work])
      {_o, 0} = git(work, ["reset", "-q", "--hard", ticket.base_commit])
      for {path, _} <- files, do: File.write!(Path.join(work, path), "mine\n")
      {_o, 0} = git(work, ["add", "-A"])
      {_o, 0} = git(work, ["commit", "-qm", "all"])

      {_o, 0} =
        git(work, ["push", "-q", "--force", "origin", "HEAD:refs/heads/" <> ticket.branch])

      ticket = finish!(ticket)

      assert ticket.state == "resolving"
      assert length(visit(ticket)["paths"]) == 5
      assert Forge.Update.said(visit(ticket)) =~ "in f1.txt and 4 more; went to resolving"
      assert Forge.Update.conflict_words(visit(ticket)["paths"], "main") =~ "and 2 more"
    end
  end

  describe "the ticket's own cap" do
    # The cap is read where the step takes its edge on its own authority, as after a job: a ticket
    # that spent past it before entering the step (a person moved it in) is stuck here, and the
    # branch has still been brought up to date, since the cap is about jobs and the step runs none.
    test "a ticket past it is stuck by the step, which has still brought the branch up",
         context do
      %{bare: bare, ticket: ticket} = context
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      end_job!(ticket)

      ticket
      |> Ecto.Changeset.change(state: "refresh", usage: 6_000_000)
      |> Repo.update!()

      assert Engine.recover_updates() == 1

      moved = Tickets.get!(ticket.id)
      assert moved.status == :stuck
      assert moved.state == "refresh"
      assert Engine.why_stuck(moved) == "ticket usage cap reached"
      assert head(bare, moved) == main
      assert %{"result" => "forwarded"} = visit(moved)
    end
  end

  describe "the pin" do
    test "is moved to the commit the code was brought up to, by the engine", context do
      %{bare: bare, ticket: ticket} = context
      pinned = ticket.workflow_commit

      main =
        commit_to(bare, "main", %{".forge/agents/implement.md" => "Implement, differently.\n"})

      ticket = finish!(ticket)

      assert ticket.workflow_commit == main
      assert %{"from" => ^pinned, "to" => ^main} = latest_payload(ticket, "ticket.repinned")
      assert [%{actor: %{"kind" => "system"}}] = events_of(ticket, "ticket.repinned")
      assert %{"repin" => %{"from" => ^pinned, "to" => ^main}} = visit(ticket)
    end

    test "is moved on a conflict too, and the next job reads the prompt there", context do
      %{bare: bare, ticket: ticket} = context
      own_commit!(context, "README.md", "mine")

      main =
        commit_to(bare, "main", %{
          "README.md" => "trunk\n",
          ".forge/agents/integrate.md" => "Merge it, newer words.\n"
        })

      ticket = finish!(ticket)

      assert ticket.state == "resolving"
      assert ticket.workflow_commit == main
      [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "resolving"))
      assert Jobs.spec(job).prompt =~ "newer words"
      assert Jobs.spec(job).commit == main
    end

    test "is skipped, with the reason, when the workflow there has no such state", context do
      %{bare: bare, ticket: ticket} = context
      pinned = ticket.workflow_commit

      without = """
      version: 1
      initial: implementing
      states:
        implementing:
          prompt: agents/implement.md
          produces: [implementation.md, changeset, commit-message]
          budget: { turns: 10, tokens: 200k }
        review_ready: {}
        merged:
          on_enter: merge
      transitions:
        - { from: implementing, to: review_ready }
        - { from: review_ready, to: merged, approve: [changeset] }
      limits:
        ticket_tokens: 5M
      """

      commit_to(bare, "main", %{".forge/workflow.yml" => without})

      ticket = finish!(ticket)

      assert ticket.workflow_commit == pinned
      assert ticket.state == "review_ready"
      assert %{"repin" => %{"skipped" => "no_state", "reason" => reason}} = visit(ticket)
      assert reason =~ "has no state refresh"
      assert events_of(ticket, "ticket.repinned") == []
    end

    test "is skipped when the step there is no step", context do
      %{bare: bare, ticket: ticket} = context

      plain = """
      version: 1
      initial: implementing
      states:
        implementing:
          prompt: agents/implement.md
          produces: [implementation.md, changeset, commit-message]
          budget: { turns: 10, tokens: 200k }
        refresh:
          prompt: agents/implement.md
          budget: { turns: 10, tokens: 200k }
        review_ready: {}
        merged:
          on_enter: merge
      transitions:
        - { from: implementing, to: refresh }
        - { from: refresh, to: review_ready }
        - { from: review_ready, to: merged, approve: [changeset] }
      limits:
        ticket_tokens: 5M
      """

      commit_to(bare, "main", %{".forge/workflow.yml" => plain})
      ticket = finish!(ticket)

      assert %{"repin" => %{"skipped" => "not_an_update_step"}} = visit(ticket)
      # The pin it has still has the step, so the edge out is taken on it.
      assert ticket.state == "review_ready"
    end

    test "is skipped when the file does not validate, saying the first error", context do
      %{bare: bare, ticket: ticket} = context

      commit_to(bare, "main", %{
        ".forge/workflow.yml" =>
          "version: 1\ninitial: nowhere\nstates: {}\ntransitions: []\nlimits:\n  ticket_tokens: 5M\n"
      })

      ticket = finish!(ticket)

      assert %{"repin" => %{"skipped" => "invalid", "reason" => reason}} = visit(ticket)
      assert reason =~ "the workflow there does not validate: "
      assert ticket.state == "review_ready"
    end

    test "is skipped, saying so, when the type's file is gone", context do
      %{ticket: ticket, bare: bare} = context
      # A ticket with a type the default branch no longer has a file for.
      ticket = ticket |> Ecto.Changeset.change(ticket_type: "gone") |> Repo.update!()
      commit_to(bare, "main", %{"other.txt" => "x\n"})

      ticket = finish!(ticket)

      assert %{"repin" => %{"skipped" => "type_gone", "reason" => reason}} = visit(ticket)
      assert reason =~ "is gone there"
    end
  end

  describe "a pin with no step" do
    @describetag workflow: [plain: true]

    test "never passes through one, and a person's re-pin is how it gets it", context do
      %{bare: bare, ticket: ticket} = context
      pinned = ticket.workflow_commit
      commit_to(bare, "main", %{".forge/workflow.yml" => workflow()})
      job = end_job!(ticket)

      # Left alone by the default branch changing: nothing re-pins it, and it goes the old way.
      {:ok, moved} = Engine.after_job(Tickets.get!(ticket.id), job, "done")
      assert moved.state == "review_ready"
      assert moved.workflow_commit == pinned
      assert events_of(moved, "ticket.branch_updated") == []
      assert events_of(moved, "ticket.repinned") == []
    end

    test "re-pinned by a person onto the step, the ticket then passes through it", context do
      %{bare: bare, ticket: ticket, user: user} = context
      job = end_job!(ticket)
      main = commit_to(bare, "main", %{".forge/workflow.yml" => workflow()})

      {:ok, repinned} = Engine.repin(ticket, user.id)
      assert repinned.workflow_commit == main
      assert [%{actor: %{"kind" => "user"}}] = events_of(repinned, "ticket.repinned")

      {:ok, moved} = Engine.after_job(repinned, job, "done")

      assert moved.state == "review_ready"
      assert [%{}] = events_of(moved, "ticket.branch_updated")
    end
  end

  describe "the job an edge out of the step makes" do
    @tag workflow: [job: true]
    test "is made on the moved base: its changeset is the ticket's own change", context do
      %{bare: bare, ticket: ticket} = context
      own_commit!(context)
      commit_to(bare, "main", %{"from-main.txt" => "main's\n"}, "Merge ticket/9: Other")

      ticket = finish!(ticket)

      assert ticket.state == "building"

      job =
        ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == "building")) |> List.last()

      assert %{content: diff} = Enum.find(Jobs.spec(job).inputs, &(&1.name == "changeset"))

      assert diff =~ "feature.txt"
      refute diff =~ "from-main.txt"
      assert head(bare, ticket) != ticket.base_commit
    end
  end

  describe "every job is told the ticket's base" do
    test "a job's spec names it, and it moved with the branch", context do
      %{bare: bare, ticket: ticket, project: project} = context
      own_commit!(context)
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      ticket = finish!(ticket)
      assert ticket.base_commit == main

      # The next job is made on the moved base, and says so: `git diff <base>..HEAD` is the change.
      assert ticket.state == "review_ready"
      job = ticket.id |> Jobs.for_ticket() |> List.first()
      {:ok, token, _row} = Tokens.issue_for_job(job, ticket, project)

      assert Jobs.assignment(job, ticket, project, token)["spec"]["base"] == main
    end

    test "a conversation about a ticket is told it too", context do
      %{ticket: ticket, project: project} = context
      {:ok, chat} = Forge.Conversations.open(project, "about this", ticket: ticket)
      chat = Jobs.get!(chat.id)

      spec = Jobs.assignment(chat, ticket, project, "token")["spec"]

      assert spec["base"] == ticket.base_commit

      {:ok, repo_chat} = Forge.Conversations.open(project, "about the repository")
      repo_chat = Jobs.get!(repo_chat.id)

      assert Jobs.assignment(repo_chat, nil, project, "token")["spec"]["base"] == nil
    end
  end

  describe "an edge into the merge" do
    @tag workflow: [after: "merged"]
    test "names the version the step wrote, as the engine's", context do
      %{bare: bare, ticket: ticket} = context
      own_commit!(context)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      changeset!(ticket, own_commit!(context, "feature.txt", "mine two"))

      ticket = finish!(ticket)

      assert ticket.status == :done
      versions = Artifacts.versions(ticket.id, "changeset")
      assert [%{version: 1}, %{version: 2, author: %{"kind" => "system"}}] = versions

      assert %{"changeset_version" => 2, "from" => "refresh", "to" => "merged"} =
               latest_payload(ticket, "transition.taken")

      assert [%{actor: %{"kind" => "system"}}] = events_of(ticket, "ticket.merged")
    end
  end

  describe "an edge into the merge, and what an earlier approval stays" do
    @tag workflow: [after: "merged", queue: true]
    test "queued, it enters the line with the version the step wrote", context do
      %{bare: bare, ticket: ticket, user: user, project: project} = context
      own = own_commit!(context)
      changeset!(ticket, own)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")

      # A person's approval of version 1, given before the step ran: it stays on version 1.
      [one] = Artifacts.versions(ticket.id, "changeset")

      {:ok, _} =
        Ecto.Multi.new()
        |> Artifacts.put_approval(
          :approval,
          one,
          {:user, user.id},
          :approved,
          %{"from" => "review_ready", "to" => "merged"},
          nil
        )
        |> Repo.transaction()

      ticket = finish!(ticket)

      assert Forge.MergeQueue.queued?(ticket)

      # Waiting in the line is the step's work done: running it again (a restart does) records no
      # second visit and puts the ticket back in nothing.
      visits = length(events_of(ticket, "ticket.branch_updated"))
      before = head(bare, ticket)
      commit_to(bare, "main", %{"later.txt" => "x\n"}, "Merge ticket/10: Later")
      assert Engine.recover_updates() == 1
      assert length(events_of(ticket, "ticket.branch_updated")) == visits

      # And its branch has not been touched: the merge it is queued for is of the version it named.
      assert head(bare, ticket) == before
      assert [_one] = Forge.MergeQueue.list(project.id)

      assert [%{version: 1}, %{version: 2}] = Artifacts.versions(ticket.id, "changeset")
      assert [%{decision: :approved}] = Artifacts.approvals(one.id)

      two = ticket.id |> Artifacts.versions("changeset") |> List.last()
      assert Artifacts.approvals(two.id) == []
      assert %{"changeset_version" => 2} = latest_payload(ticket, "merge_queue.entered")
    end
  end

  describe "taken out of the line while resting in the step" do
    @tag workflow: [after: "merged", queue: true]
    test "the ticket sticks there and a person is offered the edge out", context do
      %{ticket: ticket, user: user, bare: bare} = context
      own = own_commit!(context)
      changeset!(ticket, own)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      ticket = finish!(ticket)
      assert Forge.MergeQueue.queued?(ticket)
      assert ticket.state == "refresh"

      assert {:ok, out} = Engine.take_out(ticket, user.id)

      # Not left active in a step that will never run again: stuck, which is what offers the edge.
      assert out.status == :stuck
      assert out.state == "refresh"
      refute Forge.MergeQueue.queued?(out)
      assert {:ok, _chosen} = Engine.choose(out, user.id, "merged")
    end
  end

  describe "someone pushing to the branch while the step runs" do
    test "one move: it decides again from the new head", context do
      %{bare: bare, ticket: ticket} = context
      own = own_commit!(context)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      theirs = commit_beside(bare, own, "theirs.txt", "a developer")
      pushes = race(bare, ref: "refs/heads/#{ticket.branch}", moves: [theirs])

      ticket = finish!(ticket)

      assert ticket.state == "review_ready"
      assert pushes.() == 2
      {:ok, parents} = Git.run(bare, ["log", "-1", "--format=%P", head(bare, ticket)])
      assert hd(String.split(parents)) == theirs
      assert %{"retried" => true, "result" => "merged", "from" => ^theirs} = visit(ticket)
    end

    test "two moves: it sticks and says someone is pushing to the branch", context do
      %{bare: bare, ticket: ticket} = context
      own = own_commit!(context)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      one = commit_beside(bare, own, "one.txt", "one")
      two = commit_beside(bare, one, "two.txt", "two")
      race(bare, ref: "refs/heads/#{ticket.branch}", moves: [one, two])

      ticket = finish!(ticket)

      assert ticket.status == :stuck
      assert ticket.state == "refresh"
      assert Engine.why_stuck(ticket) =~ "pushed to twice while it was being brought up to date"
      assert head(bare, ticket) == two
      assert %{"result" => "failed"} = visit(ticket)
    end

    test "a hook that refuses sticks the ticket and moves nothing", context do
      %{bare: bare, ticket: ticket} = context
      own = own_commit!(context)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      race(bare, ref: "refs/heads/#{ticket.branch}", refuse: true)

      ticket = finish!(ticket)

      assert ticket.status == :stuck
      assert head(bare, ticket) == own
      assert Engine.why_stuck(ticket) =~ "refused"
    end
  end

  describe "a hold" do
    test "a transition into the step that waits for release runs it then", context do
      %{bare: bare, ticket: ticket, user: user} = context
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      before = head(bare, ticket)
      {:ok, held} = Engine.hold(ticket, {:user, user.id})

      # The engine would take its edge into the step; held, it keeps it for the release.
      job = end_job!(held)
      {:ok, held} = Engine.after_job(Tickets.get!(held.id), job, "done")
      assert held.state == "implementing"
      assert head(bare, held) == before

      {:ok, released} = Engine.release(held, {:user, user.id})

      assert released.state == "review_ready"
      assert head(bare, released) == main
      assert %{"result" => "forwarded"} = visit(released)
    end

    test "entering the step while held moves nothing, and release runs it", context do
      %{bare: bare, ticket: ticket, user: user} = context
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      before = head(bare, ticket)
      end_job!(ticket)
      # A person's own move into the step, from a state that waits for them, on a held ticket.
      ticket = ticket |> Ecto.Changeset.change(state: "asking") |> Repo.update!()
      {:ok, held} = Engine.hold(ticket, {:user, user.id})

      {:ok, _moved} = Engine.choose(held, user.id, "refresh")
      held = Tickets.get!(held.id)

      assert held.state == "refresh"
      assert held.held_entry["state"] == "refresh"
      assert head(bare, held) == before
      assert events_of(held, "ticket.branch_updated") == []
      assert {:entry, "refresh"} = Engine.waiting_on_release(held)

      {:ok, released} = Engine.release(Tickets.get!(held.id), {:user, user.id})

      assert released.state == "review_ready"
      assert released.held_entry == nil
      assert head(bare, released) == main
      assert %{"result" => "forwarded"} = visit(released)
    end

    test "a hold that landed after the entering transaction has no entry kept, and release runs it",
         context do
      %{bare: bare, ticket: ticket, user: user} = context
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      end_job!(ticket)

      # In the step and held, with nothing kept: the gate skipped a run, as it does for a held ticket.
      step = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()
      {:ok, held} = Engine.hold(step, {:user, user.id})
      assert held.held_entry == nil

      {:ok, released} = Engine.release(held, {:user, user.id})

      assert released.state == "review_ready"
      assert head(bare, released) == main
    end

    test "a held visit that conflicted waits for release, and release sends it down the route",
         context do
      %{ticket: ticket, user: user, project: project} = context
      conflicting!(context)
      end_job!(ticket)
      step = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()
      {:ok, held} = Engine.hold(step, {:user, user.id})
      result = Forge.Update.run(held)
      assert {:conflict, %{paths: ["README.md"]}, false} = result

      Engine.record_update(held, project, result, :none)

      held = Tickets.get!(ticket.id)
      assert %{"result" => "conflicted", "held" => true} = payload = visit(held)
      refute Map.has_key?(payload, "went")
      assert Forge.Update.said(payload) =~ "; waits for release"

      {:ok, released} = Engine.release(held, {:user, user.id})
      assert released.state == "resolving"
    end

    test "a queue entry made during the git half stops the record: no second visit", context do
      %{ticket: ticket, bare: bare, project: project} = context
      end_job!(ticket)
      step = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()
      head = head(bare, ticket)
      facts = %{head: head, default: head, to: head, retried: false, merges: [], more: 0}

      # Another run of this entry took the edge into the merge and queued the ticket, which stays
      # `active` in the step's state as far as the ticket row goes; this run's record must meet it.
      Repo.insert!(%Forge.MergeQueue.Entry{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        position: 1,
        from_state: "refresh",
        to_state: "merged",
        edge_outcome: "done",
        changeset_sha: String.duplicate("a", 40),
        changeset_version: 1,
        status: :waiting
      })

      Engine.record_update(step, project, {:current, facts}, :none)

      assert events_of(step, "ticket.branch_updated") == []
      assert Tickets.get!(ticket.id).state == "refresh"
    end

    test "a hold that lands during the git half is kept for release", context do
      %{ticket: ticket, user: user, project: project, bare: bare} = context
      end_job!(ticket)

      # The ticket is in the step and was held after the gate looked: what the record meets.
      step = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()
      {:ok, held} = Engine.hold(step, {:user, user.id})
      head = head(bare, ticket)
      facts = %{head: head, default: head, to: head, retried: false, merges: [], more: 0}

      Engine.record_update(held, project, {:current, facts}, :none)

      held = Tickets.get!(ticket.id)
      assert held.state == "refresh"
      assert held.status == :active
      assert held.held_entry["state"] == "refresh"
      assert %{"result" => "current", "held" => true} = visit(held)
      assert Enum.all?(events_of(held, "transition.taken"), &(&1.payload["from"] != "refresh"))
    end
  end

  describe "nobody acts inside a running step" do
    setup %{ticket: ticket} do
      ticket =
        ticket
        |> Ecto.Changeset.change(state: "refresh", status: :active)
        |> Repo.update!()

      %{ticket: ticket}
    end

    # Each is refused for the step, and not for the pending job the ticket still has: the guard is
    # asked first, so the word is `updating` and not `job_live`.
    test "choose, repin and integrate are refused while it runs", context do
      %{ticket: ticket, user: user, bare: bare} = context
      commit_to(bare, "main", %{".forge/agents/implement.md" => "Later words.\n"})

      assert {:error, {:updating, "refresh"}} = Engine.choose(ticket, user.id, "review_ready")
      assert {:error, {:updating, "refresh"}} = Engine.integrate(ticket, user.id)
      assert {:error, {:updating, "refresh"}} = Engine.repin(ticket, user.id)
      assert {:error, {:no_job_in, "refresh"}} = Engine.retry(ticket, user.id)
    end

    test "an edge into the step is not a conflict route", %{ticket: ticket, user: user} do
      # In `implementing`, whose edge leads into the step, which names a conflict state: the route
      # `integrate/2` takes is a merging state's, and the step is entered by a transition.
      end_job!(ticket)
      ticket = ticket |> Ecto.Changeset.change(state: "implementing") |> Repo.update!()
      workflow = Tickets.workflow(ticket)

      assert Engine.integrates_to(ticket, workflow) == nil
      assert {:error, :no_conflict_route} = Engine.integrate(ticket, user.id)
    end

    test "a step that stuck the ticket offers its one edge out", %{ticket: ticket, user: user} do
      ticket = ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()

      assert Engine.offered_transitions(ticket, Tickets.workflow(ticket)) == ["review_ready"]
      assert {:ok, moved} = Engine.choose(ticket, user.id, "review_ready")
      assert moved.state == "review_ready"
    end
  end

  describe "a pin the validator would have refused" do
    test "a step with no edge out sticks the ticket in words and does not raise", context do
      %{ticket: ticket} = context
      end_job!(ticket)

      pin =
        Map.update!(ticket.workflow, "transitions", fn edges ->
          Enum.reject(edges, &(&1["from"] == "refresh"))
        end)

      step = ticket |> Ecto.Changeset.change(state: "refresh", workflow: pin) |> Repo.update!()

      Engine.enter(step, Tickets.workflow(step), "refresh", nil)

      moved = Tickets.get!(ticket.id)
      assert moved.status == :stuck
      assert Engine.why_stuck(moved) == "the update step has no transition out"
    end
  end

  describe "recovery" do
    test "runs the step for a ticket a crash left active in it", context do
      %{bare: bare, ticket: ticket} = context
      main = commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      end_job!(ticket)
      ticket |> Ecto.Changeset.change(state: "refresh", status: :active) |> Repo.update!()

      assert Engine.recover_updates() == 1

      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "review_ready"
      assert head(bare, ticket) == main
      assert Engine.recover_updates() == 0
    end

    test "a second run of an entry that already finished records nothing", context do
      %{ticket: ticket} = context
      ticket = finish!(ticket)
      before = Events.for_ticket(ticket.id) |> length()

      workflow = Tickets.workflow(ticket)
      Engine.enter(%{ticket | state: "refresh"}, workflow, "refresh", nil)

      assert Events.for_ticket(ticket.id) |> length() == before
      assert Tickets.get!(ticket.id).state == "review_ready"
    end

    # A hold and a release between a first run's push and its record start a second; the second
    # must not decide on the branch the first has already moved, or the platform's merge is recorded
    # as "already up to date" and no version is written for it. It waits for the first instead.
    test "two runs of one entry do not overlap: the second waits for the first", context do
      %{ticket: ticket} = context
      own_commit!(context)
      commit_to(context.bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      end_job!(ticket)
      step = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()
      workflow = Tickets.workflow(step)

      # What a first run holds from its gate to its record, held by the test.
      holder = self()
      key = {:forge_update, ticket.id}

      first =
        Task.async(fn ->
          :global.trans({key, self()}, fn ->
            send(holder, :held)

            receive do
              :go -> :ok
            end
          end)
        end)

      assert_receive :held

      second = Task.async(fn -> Engine.enter(step, workflow, "refresh", nil) end)

      # The one wait on time in this file: that a run is *not* finished is shown by its not being so
      # after a moment; the other half (that it finishes once the lock is free) is not timed.
      assert Task.yield(second, 300) == nil
      assert events_of(step, "ticket.branch_updated") == []

      send(first.pid, :go)
      Task.await(first)
      Task.await(second)

      assert [_one] = events_of(step, "ticket.branch_updated")
      assert %{"result" => "merged"} = visit(step)
    end

    # Every way into the step ends the job before it, so a live job here is a state the product
    # does not make; the guard is kept against a second writer, and shown against a row made by hand.
    test "a ticket with a job of its own still live sticks, and the branch stays", context do
      %{bare: bare, ticket: ticket} = context
      before = head(bare, ticket)
      commit_to(bare, "main", %{"other.txt" => "x\n"}, "Merge ticket/9: Other")
      ticket = ticket |> Ecto.Changeset.change(state: "refresh") |> Repo.update!()

      ticket = Engine.enter(ticket, Tickets.workflow(ticket), "refresh", nil)

      assert Tickets.get!(ticket.id).status == :stuck
      assert Engine.why_stuck(Tickets.get!(ticket.id)) =~ "a job of this ticket is still running"
      assert head(bare, ticket) == before
    end
  end

  describe "a conflict, resolved" do
    test "the job merges the default branch in and the ticket goes on past the step", context do
      %{bare: bare, ticket: ticket} = context
      {_own, main} = conflicting!(context)
      ticket = finish!(ticket)
      assert ticket.state == "resolving"

      resolved = integrate!(bare, ticket)
      ticket = finish!(ticket, "resolving", "done")

      assert ticket.state == "review_ready"
      assert head(bare, ticket) == resolved
      assert Git.ancestor?(bare, main, resolved)
      # The step ran once: the resolution is the job's, and nothing brought the branch up again.
      assert length(events_of(ticket, "ticket.branch_updated")) == 1
    end
  end

  describe "a loop through a person" do
    test "gave up, then tried again through the step", context do
      %{bare: bare, ticket: ticket, user: user} = context
      {_own, _main} = conflicting!(context)
      ticket = finish!(ticket)
      assert ticket.state == "resolving"

      ticket = finish!(ticket, "resolving", "gave_up")
      assert ticket.state == "asking"

      # The person fixes the default branch's side, and sends it back through the step.
      commit_to(bare, "main", %{"README.md" => "the branch's version\n"}, "settled")
      {:ok, ticket} = Engine.choose(ticket, user.id, "refresh")

      assert ticket.state == "review_ready"
      assert length(events_of(ticket, "ticket.branch_updated")) == 2
    end
  end

  test "the events say what the step did, in words", context do
    %{ticket: ticket} = context
    ticket = finish!(ticket)

    assert Events.summary(List.last(events_of(ticket, "ticket.branch_updated"))) =~
             "already up to date with main at"
  end
end
