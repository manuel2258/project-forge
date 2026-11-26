defmodule Forge.TakeoverTest do
  @moduledoc """
  A ticket taken over to be worked on outside forge, and handed back
  (`docs/design/outside-work.md`): a hold with a name on it, whose hand-back records what was
  pushed as the ticket's change and continues from a step the one handing back picks.

  Each test aims at the guard it names. The numbers are ticket 79's acceptance criteria.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Events, FakeWorker, Git, Jobs, Operator, Tickets}
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job
  alias Forge.Tickets.Takeover

  setup do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "takeover-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, ticket} = Operator.admit(project, user, %{title: "An idea", on_hold: false})
    %{project: project, user: user, repo: repo, ticket: ticket, worker: FakeWorker.connect()}
  end

  defp fresh(ticket), do: Tickets.get!(ticket.id)
  defp pending(ticket), do: Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

  defp events(ticket, type),
    do: ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == type))

  defp takeovers(ticket), do: Repo.all(from k in Takeover, where: k.ticket_id == ^ticket.id)

  defp in_planning!(ticket, user, worker) do
    [job] = pending(ticket)
    {:ok, _} = FakeWorker.run(job, worker, "success", doc: "refinement.md")
    {:ok, ticket} = Engine.decide(fresh(ticket), user.id, :approved, "ok")
    assert ticket.state == "planning"
    ticket
  end

  describe "taking over (criteria 1, 2, 34)" do
    test "holds the ticket with the taker's name, through the door it came by", context do
      %{ticket: ticket, user: user} = context

      assert {:ok, taken} = Operator.take_over(ticket, user, via: :page)
      assert taken.held_at
      assert Forge.Tickets.Ticket.taken_over?(taken)

      assert [%Takeover{user_id: user_id, token_id: nil, via: "page", state: "refining"} = row] =
               takeovers(ticket)

      assert user_id == user.id

      assert row.head ==
               elem(
                 Git.resolve(
                   Forge.Projects.repo_path(context.project),
                   "refs/heads/" <> ticket.branch
                 ),
                 1
               )

      assert [%{actor: %{"kind" => "user", "id" => ^user_id}, payload: %{"via" => "page"}}] =
               events(ticket, "ticket.taken_over")
    end

    test "a ticket already taken over is refused naming who and since, the same person too",
         context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)

      assert {:error, {:already_taken_over, {:user, id}, %DateTime{}}} =
               Operator.take_over(taken, user)

      assert id == user.id

      other = member_fixture(project)

      assert {:error, {:already_taken_over, {:user, ^id}, _since}} =
               Operator.take_over(taken, other)

      assert length(takeovers(ticket)) == 1
    end

    test "a ticket on an ordinary hold gains the name and keeps its hold", context do
      %{ticket: ticket, user: user} = context
      {:ok, held} = Operator.hold(ticket, user)

      {:ok, taken} = Operator.take_over(held, user)
      assert taken.held_at == held.held_at
      assert taken.takeover_id
    end

    test "a done or cancelled ticket is refused", context do
      %{ticket: ticket, user: user} = context
      {:ok, _} = Engine.cancel(ticket, user.id)
      assert {:error, {:not_holdable, :cancelled}} = Operator.take_over(fresh(ticket), user)
      assert takeovers(ticket) == []
    end

    test "a write token takes it over and is named as the holder; a read token is refused",
         context do
      %{ticket: ticket, project: project} = context
      {:ok, _secret, reader} = Tokens.issue(project, name: "ro", git: :reader, api: :read)
      {:ok, _secret, writer} = Tokens.issue(project, name: "bot", git: :reader, api: :write)

      assert {:error, :forbidden} = Operator.take_over(ticket, reader)
      assert takeovers(ticket) == []

      assert {:ok, _taken} = Operator.take_over(ticket, writer, via: :mcp)
      writer_id = writer.id
      assert [%Takeover{token_id: ^writer_id, user_id: nil, via: "mcp"}] = takeovers(ticket)
      assert [%{actor: %{"kind" => "api", "name" => "bot"}}] = events(ticket, "ticket.taken_over")
    end

    test "a member of another project may not (identity.md)", context do
      %{ticket: ticket} = context

      {:ok, other_project} =
        register_owned!(%{
          name: "elsewhere-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      stranger = member_fixture(other_project)

      assert {:error, :forbidden} = Operator.take_over(ticket, stranger)
      assert {:error, :forbidden} = Operator.hand_back(ticket, stranger)
      assert takeovers(ticket) == []
    end
  end

  describe "a run going (criterion 3)" do
    setup %{ticket: ticket, user: user, worker: worker} do
      ticket = in_planning!(ticket, user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      %{ticket: ticket, job_id: assignment["job_id"], assignment: assignment}
    end

    test "is refused without a choice and nothing is written", context do
      %{ticket: ticket, user: user} = context
      assert {:error, :running_choice} = Operator.take_over(ticket, user)
      assert {:error, :bad_running} = Operator.take_over(ticket, user, running: "maybe")
      assert takeovers(ticket) == []
      refute fresh(ticket).held_at
    end

    test "stop cancels the run and the state runs again on hand-back", context do
      %{ticket: ticket, user: user, job_id: job_id} = context

      assert {:ok, taken} = Operator.take_over(ticket, user, running: "stop")
      assert_receive {:cancel, ^job_id, :ticket_cancelled}, 1_000
      assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job_id)
      assert taken.held_entry["state"] == "planning"

      assert [%{payload: %{"running" => "stop", "jobs" => [^job_id]}}] =
               events(ticket, "ticket.taken_over")

      {:ok, _} = Jobs.hibernate(job_id, nil, "cancelled")
      assert {:ok, back} = Operator.hand_back(fresh(ticket), user)
      assert back.state == "planning"
      assert [%Job{state: "planning", attempt: 2}] = pending(ticket)
    end

    test "finish leaves the run, and its outcome waits for the hand-back", context do
      %{ticket: ticket, user: user, assignment: assignment} = context

      assert {:ok, taken} = Operator.take_over(ticket, user, running: :finish)
      assert Engine.stoppable?(taken)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "plan.md")

      held = fresh(ticket)
      assert held.state == "planning"
      assert held.held_transition
    end
  end

  describe "handing back (criteria 6-10)" do
    test "records what was pushed as the change, by whoever handed back", context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)

      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "from my pc")
      other = member_fixture(project)

      assert {:ok, back} = Operator.hand_back(taken, other, note: "polished", via: :api)
      refute back.held_at
      refute back.takeover_id

      assert {:ok, %{sha: ^sha, row: row}} = Forge.Merge.changeset(back)
      assert row.author["id"] == other.id

      assert [%Takeover{back_user_id: back_user, back_via: "api", note: "polished"} = tk] =
               takeovers(ticket)

      assert back_user == other.id
      assert tk.changeset_version_id == row.id
      assert tk.back_head == sha
      assert [%{"sha" => ^sha}] = tk.commits["list"]
      assert [%{actor: %{"id" => id}}] = events(ticket, "ticket.handed_back")
      assert id == other.id
    end

    test "records no version when the branch has not moved", context do
      %{ticket: ticket, user: user} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      before = Artifacts.latest(ticket.id, "changeset")

      assert {:ok, _back} = Operator.hand_back(taken, user)
      assert Artifacts.latest(ticket.id, "changeset") == before
      assert [%Takeover{changeset_version_id: nil, commits: %{"list" => []}}] = takeovers(ticket)
    end

    test "a head that differs from the latest version is a new one, once", context do
      %{ticket: ticket, user: user, project: project} = context
      first = commit_file_on_branch(project, ticket.branch, "a.txt", "one")
      changeset!(ticket, first)
      {:ok, taken} = Operator.take_over(ticket, user)
      second = commit_file_on_branch(project, ticket.branch, "b.txt", "two")

      {:ok, _} = Operator.hand_back(taken, user)
      assert {:ok, %{sha: ^second, version: 2}} = Forge.Merge.changeset(fresh(ticket))
      # Counted from the version's own commit, which descends from where it was taken over.
      assert [%Takeover{commits: %{"list" => [%{"sha" => ^second}]}}] = takeovers(ticket)
    end

    test "a step with no document its job needs is refused and the ticket stays taken over",
         context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")

      assert {:error, {:missing_input, _name}} =
               Operator.hand_back(taken, user, to: "implementing")

      still = fresh(ticket)
      assert still.takeover_id == taken.takeover_id
      assert still.held_at
      assert [%Takeover{handed_back_at: nil}] = takeovers(ticket)
      # What was pushed is recorded and a second try records nothing new.
      assert {:ok, %{version: 1}} = Forge.Merge.changeset(still)
      assert {:error, {:missing_input, _}} = Operator.hand_back(still, user, to: "implementing")
      assert {:ok, %{version: 1}} = Forge.Merge.changeset(fresh(ticket))
    end

    test "a hand-back refused and tried again still records the commits pushed", context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")

      # Phase one records the version before phase two refuses; the retry finds it already there.
      assert {:error, {:missing_input, _name}} =
               Operator.hand_back(taken, user, to: "implementing")

      assert {:ok, _back} = Operator.hand_back(fresh(ticket), user)

      assert [%Takeover{commits: %{"list" => [%{"sha" => ^sha}], "more" => 0}}] =
               takeovers(ticket)

      assert {:ok, %{sha: ^sha, version: 1}} = Forge.Merge.changeset(fresh(ticket))
    end

    test "a run let finish is not counted as the person's commits", context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      [withdrawn | _] = Jobs.for_ticket(ticket.id)
      # What a job that was let finish recorded after the take-over, then what the person pushed.
      by_job = commit_file_on_branch(project, ticket.branch, "job.txt", "the job's")
      changeset!(ticket, by_job, withdrawn)
      mine = commit_file_on_branch(project, ticket.branch, "mine.txt", "mine")

      assert {:ok, _} = Operator.hand_back(taken, user)

      assert [%Takeover{commits: %{"list" => [%{"sha" => ^mine}], "more" => 0}}] =
               takeovers(ticket)

      refute by_job == mine
    end

    test "a step that is not text is refused before a thing is written", context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")

      for bad <- ["refin\0ing", <<255, 254>>, 7, ["refining"]] do
        assert {:error, :bad_step} = Operator.hand_back(taken, user, to: bad)
      end

      assert Artifacts.latest(ticket.id, "changeset") == nil
      assert fresh(ticket).takeover_id
    end

    test "finishing on the PC: taken over at the merge approval, pushed, handed back (criterion 12)",
         context do
      %{ticket: ticket, user: user, project: project} = context
      first = commit_file_on_branch(project, ticket.branch, "a.txt", "one")
      changeset!(ticket, first)
      ticket = pend_merge(fresh(ticket))
      assert ticket.pending_transition["approve"] == ["changeset"]

      {:ok, taken} = Operator.take_over(ticket, user)
      second = commit_file_on_branch(project, ticket.branch, "fix.txt", "the last fix")
      assert {:ok, back} = Operator.hand_back(taken, user, note: "fixed it")

      # The approval still waits, at the same step, and what it pins is the new version.
      assert back.state == "review_ready"
      refute back.held_at
      assert back.pending_transition["approve"] == ["changeset"]
      assert {:ok, %{sha: ^second, version: 2}} = Forge.Merge.changeset(back)
    end

    test "to another step, the move is made as a person's would be and the hold is gone",
         context do
      %{ticket: ticket, user: user} = context

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Refined\n"
        })

      {:ok, taken} = Operator.take_over(ticket, user)
      assert taken.state == "refining"

      assert {:ok, back} = Operator.hand_back(taken, user, to: "planning")
      assert back.state == "planning"
      assert back.status == :active
      refute back.held_at
      assert [%Job{state: "planning"}] = pending(ticket)
    end

    test "a note is refused at the limit, never cut; invalid text is refused", context do
      %{ticket: ticket, user: user} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      limit = Takeover.note_limit()

      assert {:error, {:handback_note_too_long, ^limit}} =
               Operator.hand_back(taken, user, note: String.duplicate("é", limit + 1))

      assert {:error, :bad_note} = Operator.hand_back(taken, user, note: "a\0b")
      assert {:error, :bad_note} = Operator.hand_back(taken, user, note: <<255>>)
      assert fresh(ticket).takeover_id

      assert {:ok, _} = Operator.hand_back(taken, user, note: String.duplicate("é", limit))
      assert [%Takeover{note: note}] = takeovers(ticket)
      assert String.length(note) == limit
    end

    test "a ticket that is not taken over is refused, and a read token may not", context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, _secret, reader} = Tokens.issue(project, name: "ro", git: :reader, api: :read)
      assert {:error, :not_taken_over} = Operator.hand_back(ticket, user)

      {:ok, taken} = Operator.take_over(ticket, user)
      assert {:error, :forbidden} = Operator.hand_back(taken, reader)
      assert fresh(ticket).takeover_id
    end

    test "releasing a taken-over ticket is a hand-back to the step it rests in (criterion 10)",
         context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")

      assert {:ok, released} = Operator.release(taken, user)
      refute released.held_at
      assert {:ok, %{sha: ^sha}} = Forge.Merge.changeset(released)

      assert [%Takeover{note: nil, to_state: "refining", handed_back_at: %DateTime{}}] =
               takeovers(ticket)

      assert [_] = events(ticket, "ticket.handed_back")
    end

    test "a taken-over ticket is never refreshed: its branch is not moved to the default head (C10)",
         context do
      %{ticket: ticket, user: user, project: project} = context
      {:ok, taken} = Operator.take_over(ticket, user)
      assert Tickets.started?(taken)

      mine = commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")
      commit_to_default(project, %{"later.txt" => "after\n"})

      assert {:ok, _} = Operator.hand_back(taken, user)
      repo = Forge.Projects.repo_path(project)
      assert {:ok, ^mine} = Git.resolve(repo, "refs/heads/" <> ticket.branch)
    end
  end

  describe "while taken over (criterion 4)" do
    test "no job is placed", context do
      %{ticket: ticket, user: user} = context
      [job] = pending(ticket)
      assert job.id in Enum.map(Jobs.pending(), & &1.id)

      {:ok, _} = Operator.take_over(ticket, user)
      refute job.id in Enum.map(Jobs.pending(), & &1.id)
    end
  end
end
