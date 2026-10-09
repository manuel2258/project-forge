defmodule Forge.MergeWatchTest do
  @moduledoc """
  A merge's effect on the project's other open tickets, found before anybody approves them
  (`docs/design/git-hosting.md` § After a merge, the other tickets), what the ticket's page is told
  about it, and the person's way down the conflict route from there
  (`docs/design/workflow-grammar-v1.md` § Merging).
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Git, Jobs, Operator, Tickets}
  alias Forge.Merge.Watch

  setup do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => conflict_workflow(:b),
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "watch#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)

    %{project: project, bare: bare, user: user}
  end

  describe "after a ticket merges" do
    test "the tickets it put in conflict are found, naming it", context do
      %{project: project, user: user} = context
      merging = ticket!(context, "README.md", "the first to merge")
      waiting = ticket!(context, "README.md", "the second")
      clean = ticket!(context, "OTHER.md", "somewhere else")

      {:ok, merged} = Operator.decide(pend_merge(merging), user, :approved, nil)
      assert merged.state == "merged"

      assert [%{payload: found}] = events_of(waiting, "ticket.conflict_found")
      {:ok, head} = Git.resolve(Forge.Projects.repo_path(project), "refs/heads/main")

      assert %{
               "paths" => ["README.md"],
               "head" => ^head,
               "changeset_version" => 1,
               "cause" => %{"ticket" => number}
             } = found

      assert number == merging.number
      assert events_of(clean, "ticket.conflict_found") == []
      assert events_of(merged, "ticket.conflict_found") == []
    end

    # It conflicted before this merge too, so this merge is not what caused it, and the notice
    # does not say it was.
    test "a ticket that conflicted already is found without naming the merge", context do
      %{bare: bare, user: user} = context
      waiting = ticket!(context, "README.md", "the ticket's")
      commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "earlier")
      merging = ticket!(context, "OTHER.md", "unrelated")

      {:ok, _merged} = Operator.decide(pend_merge(merging), user, :approved, nil)

      assert [%{payload: %{"cause" => nil, "paths" => ["README.md"]}}] =
               events_of(waiting, "ticket.conflict_found")
    end

    test "is found once per changeset version", context do
      %{project: project, bare: bare} = context
      waiting = ticket!(context, "README.md", "the ticket's")
      first = commit_to(bare, "main", %{"README.md" => "one\n"}, "one")

      assert [_found] = Watch.check(project.id, first, %{"ticket" => 99})
      second = commit_to(bare, "main", %{"NOTES.md" => "two\n"}, "two")
      assert [] = Watch.check(project.id, second, %{"ticket" => 98})
      assert length(events_of(waiting, "ticket.conflict_found")) == 1

      # A new version is a new question.
      sha = commit_over_http(project, waiting.branch, "README.md", "the ticket's, again")
      changeset!(waiting, sha)
      assert [_found] = Watch.check(project.id, second, %{"ticket" => 98})
      assert length(events_of(waiting, "ticket.conflict_found")) == 2
    end

    test "a ticket that is not open, or has no changeset, is not checked", context do
      %{project: project, bare: bare, user: user} = context
      cancelled = ticket!(context, "README.md", "the ticket's")
      {:ok, _ticket} = Engine.cancel(cancelled, user.id)

      {:ok, unchanged} =
        Tickets.admit(project, %{title: "Nothing yet", body: ""}, {:user, user.id})

      head = commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")

      assert [] = Watch.check(project.id, head, nil)
      assert events_of(cancelled, "ticket.conflict_found") == []
      assert events_of(unchanged, "ticket.conflict_found") == []
    end

    # The checks run after the merge's answer, in a task of their own, outside the tests.
    test "runs in the background when not told otherwise", context do
      %{project: project, bare: bare} = context
      waiting = ticket!(context, "README.md", "the ticket's")
      head = commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")

      config = Application.get_env(:forge, Watch, [])
      Application.put_env(:forge, Watch, inline: false)
      on_exit(fn -> Application.put_env(:forge, Watch, config) end)

      # With the supervisor not answering, the merge's caller is held at handing the checks over
      # — and has checked nothing itself. Run inline, it would have.
      :sys.suspend(Forge.TaskSupervisor)
      on_exit(fn -> :sys.resume(Forge.TaskSupervisor) end)
      caller = Task.async(fn -> Watch.after_merge(project.id, head, %{"ticket" => 7}) end)

      assert Task.yield(caller, 500) == nil
      assert events_of(waiting, "ticket.conflict_found") == []

      :sys.resume(Forge.TaskSupervisor)
      assert Task.await(caller) == :ok
      Forge.Push.flush()

      assert [_found] = events_of(waiting, "ticket.conflict_found")
    end
  end

  # Nothing moved, so there is nothing to find — and a check against the head would name this
  # merge as the cause of what the commit before it did.
  test "a merge that found its commit already there checks nothing", context do
    %{project: project, bare: bare, user: user} = context
    {:ok, unchanged} = Tickets.admit(project, %{title: "No change", body: ""}, {:user, user.id})
    changeset!(unchanged, unchanged.base_commit)
    waiting = ticket!(context, "README.md", "the ticket's")
    commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")

    {:ok, merged} = Operator.decide(pend_merge(unchanged), user, :approved, nil)
    assert %{"already" => true} = latest_payload(merged, "ticket.merged")

    {:ok, chat} = Forge.Conversations.open(project, "nothing to change")
    assert {:ok, %{already: true}} = Operator.merge_chat(chat, user)

    assert events_of(waiting, "ticket.conflict_found") == []
  end

  test "a conversation's merge checks the tickets too, naming it", context do
    %{project: project, user: user} = context
    waiting = ticket!(context, "README.md", "the ticket's")
    {:ok, chat} = Forge.Conversations.open(project, "tidy the readme")
    commit_on_chat!(project, chat, "README.md", "the conversation's\n")

    assert {:ok, %{already: false}} = Operator.merge_chat(chat, user)

    assert [%{payload: %{"cause" => %{"chat" => id}}}] =
             events_of(waiting, "ticket.conflict_found")

    assert id == chat.id
  end

  # A ticket that took the route once, integrated, and was then put in conflict again by a later
  # merge: the route it took before the conflict was found does not hide the notice.
  test "the notice shows for a conflict found after the route was last taken", context do
    %{bare: bare, project: project, user: user} = context
    waiting = ticket!(context, "README.md", "the ticket's")
    commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
    {:ok, ticket} = Operator.decide(pend_merge(waiting), user, :approved, nil)
    changeset!(ticket, integrate!(bare, ticket))
    Repo.update_all(Jobs.Job, set: [status: :finished])

    head = commit_to(bare, "main", %{"README.md" => "the trunk's, later\n"}, "later")
    [_found] = Watch.check(project.id, head, %{"ticket" => 21})

    assert %{cause: %{"ticket" => 21}, send_to: "integrating"} = Watch.notice(ticket)
  end

  # The conflict that stuck the integrate-then-merge loop went nowhere, so the ticket has not taken
  # the route since the notice was found, and the notice — whose button is the way on — stays.
  test "the notice stays when the loop's bound stuck the ticket", context do
    %{bare: bare, project: project, user: user} = context
    waiting = ticket!(context, "README.md", "the ticket's")
    commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
    {:ok, ticket} = Operator.decide(pend_merge(waiting), user, :approved, nil)
    ticket = Enum.reduce(1..3, ticket, fn _round, ticket -> integration_done!(ticket) end)

    head = commit_to(bare, "main", %{"NOTES.md" => "another\n"}, "another")
    [_found] = Watch.check(project.id, head, nil)
    ticket = integration_done!(ticket)
    assert ticket.status == :stuck

    assert %{paths: ["README.md"], send_to: "integrating"} = Watch.notice(ticket)
  end

  describe "the notice" do
    setup context do
      waiting = ticket!(context, "README.md", "the ticket's")
      head = commit_to(context.bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
      [_found] = Watch.check(context.project.id, head, %{"ticket" => 12})
      %{waiting: pend_merge(waiting), head: head}
    end

    test "says what conflicts, what caused it, and where it can be sent", context do
      assert %{
               paths: ["README.md"],
               head: head,
               cause: %{"ticket" => 12},
               send_to: "integrating"
             } = Watch.notice(context.waiting)

      assert head == context.head
    end

    test "is gone once the changeset changes", %{project: project, waiting: waiting} do
      sha = commit_over_http(project, waiting.branch, "README.md", "resolved by hand")
      changeset!(waiting, sha)

      assert Watch.notice(waiting) == nil
    end

    test "is gone once the ticket took the conflict route", %{waiting: waiting, user: user} do
      {:ok, moved} = Operator.decide(waiting, user, :approved, nil)
      assert moved.state == "integrating"

      assert Watch.notice(moved) == nil
    end

    test "is not shown on a ticket that is not open", %{waiting: waiting, user: user} do
      {:ok, cancelled} = Engine.cancel(waiting, user.id)

      assert Watch.notice(cancelled) == nil
    end
  end

  describe "sending a ticket down the conflict route" do
    setup context do
      waiting = ticket!(context, "README.md", "the ticket's")
      %{waiting: pend_merge(waiting)}
    end

    test "takes it, clears the approval it would have waited for, and says why", context do
      %{bare: bare, waiting: waiting, user: user} = context
      head = commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")

      assert {:ok, moved} = Operator.integrate(waiting, user)

      assert moved.state == "integrating"
      assert moved.status == :active
      assert moved.pending_transition == nil

      assert %{"by" => "person", "head" => ^head, "from" => "review_ready", "stage" => "check"} =
               latest_payload(moved, "ticket.merge_conflicted")

      # No approval was given, so none is recorded.
      [version] = Artifacts.versions(moved.id, "changeset")
      assert Artifacts.approvals(version.id) == []

      assert [%{state: "integrating"}] =
               Enum.filter(Jobs.for_ticket(moved.id), &(&1.state == "integrating"))
    end

    # From the integrating state itself — route (b) has an edge into the merge — once its job is no
    # longer live: what a person does after the engine stopped going round.
    test "is offered, and taken, only while nothing is live in the state", context do
      %{bare: bare, waiting: waiting, user: user} = context
      commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
      {:ok, integrating} = Operator.decide(waiting, user, :approved, nil)
      workflow = Tickets.workflow(integrating)

      assert Engine.integrates_to(integrating, workflow) == nil
      assert {:error, {:job_live, "integrating"}} = Operator.integrate(integrating, user)

      Repo.update_all(Jobs.Job, set: [status: :finished])
      assert Engine.integrates_to(integrating, workflow) == "integrating"
      assert {:ok, again} = Operator.integrate(integrating, user)
      assert again.state == "integrating"
      assert length(events_of(again, "ticket.merge_conflicted")) == 2
    end

    test "is refused when the changeset merges cleanly after all", context do
      %{waiting: waiting, user: user} = context

      assert {:error, :merges_cleanly} = Operator.integrate(waiting, user)
      assert Tickets.get!(waiting.id).state == "review_ready"
    end

    test "is refused where the state has no edge into a merge that names a route", context do
      %{bare: bare, waiting: waiting, user: user} = context
      commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
      implementing = waiting |> Ecto.Changeset.change(state: "implementing") |> Repo.update!()

      assert {:error, {:job_live, "implementing"}} = Operator.integrate(implementing, user)

      Repo.update_all(Jobs.Job, set: [status: :finished])
      assert {:error, :no_conflict_route} = Operator.integrate(implementing, user)
    end

    # A workflow from before the key: the merge it leads to says nowhere for a conflict to go.
    test "is refused where the merge names no on_conflict", %{user: user} do
      bare =
        seeded_repo(%{
          ".forge/workflow.yml" => conflict_workflow(:plain),
          ".forge/agents/integrate.md" => "Merge the default branch in.\n"
        })

      {:ok, project} =
        register_owned!(%{name: "plain#{System.unique_integer([:positive])}", repo_path: bare})

      join!(project, user)
      waiting = ticket!(%{project: project, user: user}, "README.md", "the ticket's")
      head = commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
      [_found] = Watch.check(project.id, head, nil)
      waiting = pend_merge(waiting)

      assert {:error, :no_conflict_route} = Operator.integrate(waiting, user)
      assert %{send_to: nil, paths: ["README.md"], cause: nil} = Watch.notice(waiting)
    end

    test "is refused for a ticket that is not open", context do
      %{bare: bare, waiting: waiting, user: user} = context
      commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "trunk")
      {:ok, cancelled} = Engine.cancel(waiting, user.id)

      assert {:error, {:not_open, :cancelled}} = Operator.integrate(cancelled, user)
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # A ticket whose branch changes `path`, with that commit recorded as its changeset.
  defp ticket!(%{project: project, user: user}, path, content) do
    {:ok, ticket} = Tickets.admit(project, %{title: content, body: ""}, {:user, user.id})
    sha = commit_over_http(project, ticket.branch, path, content)
    changeset!(ticket, sha)
    ticket
  end

  # A conversation's commit, pushed as its worker would: by the bare repository's path, with the
  # authority the platform's own push has.
  defp commit_on_chat!(project, chat, path, content) do
    repo = Forge.Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)
    commit_to(repo, branch, %{path => content}, "from the conversation")
  end
end
