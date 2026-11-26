defmodule Forge.KeepWorkTest do
  @moduledoc """
  A job whose branch moved under it (`docs/design/outside-work.md` § A job's push, § Keeping the
  job's work): the ticket sticks naming what arrived and where the work is kept, and **Keep the
  job's work** merges the kept commit onto the new head and carries on as the job's own outcome
  would have. The numbers are ticket 79's acceptance criteria.

  What the worker reports is made by hand: a commit beside the lease that no ref names but
  `refs/forge/kept/<job id>`, the branch moved by a commit of someone else's, and a result
  carrying `branch_moved`.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, FakeWorker, Git, Jobs, Operator, Tickets}
  alias Forge.Git.Tokens

  setup do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "keep-#{System.unique_integer([:positive])}", repo_path: repo})

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
  defp head(repo, ticket), do: elem(Git.resolve(repo, "refs/heads/" <> ticket.branch), 1)

  defp events(ticket, type),
    do: ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == type))

  # A run of the ticket's first state that ends with its branch moved: `kept` is its own commit
  # beside the lease, under the kept ref, and `arrived` what somebody pushed meanwhile.
  # `:outcome` is what the run would have ended on — `:declared` the scenario's, nil for a park.
  defp moved_run!(context, opts \\ []) do
    %{ticket: ticket, worker: worker, project: project, repo: repo} = context
    [job] = pending(ticket)
    assignment = FakeWorker.assign(job, worker)
    lease = head(repo, ticket)

    {kept_path, kept_content} = Keyword.get(opts, :kept, {"kept.txt", "from the job"})
    {their_path, their_content} = Keyword.get(opts, :arrived, {"theirs.txt", "from a person"})

    kept = commit_beside(repo, lease, kept_path, kept_content)

    unless Keyword.get(opts, :unkept, false),
      do: {:ok, _} = Git.run(repo, ["update-ref", "refs/forge/kept/#{job.id}", kept])

    for pusher <- Keyword.get(opts, :pushers, []),
        do:
          Events.append("branch.pushed", pusher, %{
            ticket_id: ticket.id,
            payload: %{"ref" => "refs/heads/" <> ticket.branch, "from" => lease, "to" => lease}
          })

    arrived = commit_file_on_branch(project, ticket.branch, their_path, their_content)

    FakeWorker.put_transcript(assignment)

    result =
      FakeWorker.result(assignment, Keyword.get(opts, :scenario, "success"),
        doc: Keyword.get(opts, :doc, "refinement.md")
      )

    outcome =
      case Keyword.get(opts, :outcome, :declared) do
        :declared -> result.declared_outcome
        other -> other
      end

    moved = %{"lease" => lease, "kept" => kept, "remote" => arrived, "outcome" => outcome}
    {:ok, _job} = Jobs.complete(job.id, %{result | branch_moved: moved})
    %{job: job, lease: lease, kept: kept, arrived: arrived}
  end

  describe "the stop (criteria 17, 30)" do
    test "sticks the ticket saying what arrived, who pushed it and where the work is kept",
         context do
      %{ticket: ticket, repo: repo} = context

      {:ok, token_secret, writer} =
        Tokens.issue(context.project, name: "bot", git: :reader, api: :write)

      assert is_binary(token_secret)

      run = moved_run!(context, pushers: [{:api, writer.id, "bot"}])

      stuck = fresh(ticket)
      assert stuck.status == :stuck
      assert Artifacts.latest(ticket.id, "changeset") == nil

      stop = Engine.branch_moved_stop(stuck)
      assert stop["job_id"] == run.job.id
      assert stop["lease"] == run.lease
      assert stop["kept"] == run.kept
      assert stop["head"] == run.arrived
      assert [%{"sha" => sha, "subject" => _}] = stop["arrived"]
      assert sha == run.arrived
      assert [%{"kind" => "api", "name" => "bot"}] = stop["pushers"]

      assert Engine.why_stuck(stuck) =~ "branch moved"
      # The branch is where the other person left it: nothing of the job's was pushed.
      assert head(repo, ticket) == run.arrived
    end

    test "the job's own pushes are not among the pushers", context do
      run_ctx = Map.put(context, :ticket, context.ticket)
      [job] = pending(context.ticket)

      run =
        moved_run!(run_ctx, pushers: [{:job, job.id}, {:api, Ecto.UUID.generate(), "other"}])

      stop = Engine.branch_moved_stop(fresh(context.ticket))
      assert stop["job_id"] == run.job.id
      assert [%{"kind" => "api", "name" => "other"}] = stop["pushers"]
    end

    test "a ticket that is not stuck for a moved branch has no stop", context do
      assert Engine.branch_moved_stop(fresh(context.ticket)) == nil
    end
  end

  describe "what else ends a run on a moved branch" do
    test "a run the account's limit stopped is still a moved-branch stop, not a requeue",
         context do
      %{ticket: ticket} = context
      run = moved_run!(context, scenario: "rate_limited", outcome: "error")

      stuck = fresh(ticket)
      assert stuck.status == :stuck
      assert %{"job_id" => job_id, "kept" => kept} = Engine.branch_moved_stop(stuck)
      assert job_id == run.job.id and kept == run.kept
    end

    test "a run paused for an update that kept its work is a moved-branch stop, not a resume",
         context do
      %{ticket: ticket, worker: worker, repo: repo, project: project} = context
      [job] = pending(ticket)
      FakeWorker.assign(job, worker)
      lease = head(repo, ticket)
      kept = commit_beside(repo, lease, "kept.txt", "from the job")
      arrived = commit_file_on_branch(project, ticket.branch, "theirs.txt", "from a person")

      assert {:ok, _} = Jobs.hibernate(job.id, nil, "update", nil, kept)

      stuck = fresh(ticket)
      assert stuck.status == :stuck
      stop = Engine.branch_moved_stop(stuck)
      assert %{"job_id" => job_id, "kept" => ^kept, "outcome" => nil} = stop
      assert job_id == job.id
      # The pause carries only the kept commit; what arrived is counted from where it and the
      # branch last met, which is the commit the run started from.
      assert stop["lease"] == lease
      assert [%{"sha" => ^arrived}] = stop["arrived"]
      # Not back in the queue, where a resume would believe its edits are in the tree.
      assert %Forge.Jobs.Job{status: :finished} = Jobs.get!(job.id)
      assert pending(ticket) == []
    end
  end

  describe "keeping the job's work (criterion 30)" do
    test "the job made next is handed a changeset diffed from the base the keep moved", context do
      %{ticket: ticket, user: user, repo: repo, project: project} = context
      # A state that reads the `changeset`: the input is computed from `base_commit` of the ticket
      # the run again is built from, when the job is made.
      {:ok, _} =
        Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content: "# Plan\n"
        })

      {:ok, _} =
        Forge.Artifacts.record_version(ticket.id, "implementation.md", :document, :system, %{
          content: "# Done\n"
        })

      {:ok, taken} = Operator.take_over(ticket, user)
      {:ok, _} = Operator.hand_back(taken, user, to: "verifying")
      assert fresh(ticket).state == "verifying"

      run = moved_run!(context, outcome: nil, doc: "report.md")
      # The default branch moves on and the person's push took it into the branch.
      landed = commit_to_default(project, %{"landed.txt" => "landed\n"})
      {:ok, tree} = Forge.Merge.merge_tree(repo, run.arrived, landed)

      {:ok, joined} =
        Forge.Merge.commit_tree(repo, tree, [run.arrived, landed], "Merge main\n", nil)

      {:ok, _} = Git.run(repo, ["update-ref", "refs/heads/" <> ticket.branch, joined])
      refute fresh(ticket).base_commit == landed

      assert {:ok, _} = Operator.keep_work(fresh(ticket), user, run.job.id)

      assert fresh(ticket).base_commit == landed
      assert [%{state: "verifying", attempt: 2, spec: %{"inputs" => inputs}}] = pending(ticket)
      assert %{"content" => diff} = Enum.find(inputs, &(&1["name"] == "changeset"))
      # What the ticket adds, not what the default branch landed meanwhile.
      assert diff =~ "kept.txt"
      refute diff =~ "landed.txt"
    end

    test "the guard is asked again inside the transaction", context do
      %{ticket: ticket, repo: repo} = context
      run = moved_run!(context)
      before = head(repo, ticket)
      # Allowed before any git work, refused by the time it is recorded: the actor lost the right.
      asked = :counters.new(1, [])

      allow = fn ->
        :counters.add(asked, 1, 1)
        if :counters.get(asked, 1) == 1, do: :ok, else: {:error, :forbidden}
      end

      assert {:error, :forbidden} =
               Engine.keep_work(fresh(ticket), {:user, Ecto.UUID.generate()}, run.job.id,
                 allow: allow
               )

      assert :counters.get(asked, 1) == 2
      assert events(ticket, "ticket.work_kept") == []
      assert fresh(ticket).status == :stuck
      # Git first, then the record: the merge is on the branch and nothing was recorded.
      refute head(repo, ticket) == before
    end

    test "a run whose state records a changeset records none when its branch moved", context do
      %{ticket: ticket, user: user, worker: worker} = context
      [first] = pending(ticket)
      {:ok, _} = FakeWorker.run(first, worker, "success", doc: "refinement.md")
      {:ok, _} = Engine.decide(fresh(ticket), user.id, :approved, "ok")

      {:ok, _} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Plan\n"
        })

      {:ok, taken} = Operator.take_over(fresh(ticket), user, running: :stop)
      {:ok, _} = Operator.hand_back(taken, user, to: "implementing")
      assert fresh(ticket).state == "implementing"

      run = moved_run!(context, doc: "implementation.md")

      assert fresh(ticket).status == :stuck
      assert Artifacts.latest(ticket.id, "changeset") == nil
      assert Engine.branch_moved_stop(fresh(ticket))["job_id"] == run.job.id
    end

    test "merges it onto the new commits and carries on as the job's outcome would have",
         context do
      %{ticket: ticket, user: user, repo: repo} = context
      run = moved_run!(context)

      assert {:ok, kept} = Operator.keep_work(fresh(ticket), user, run.job.id, via: :page)
      refute kept.status == :stuck
      assert kept.pending_transition

      new = head(repo, ticket)
      refute new in [run.arrived, run.kept]

      assert {:ok, parents} = Git.run(repo, ["rev-list", "--parents", "-n", "1", new])
      assert String.split(String.trim(parents)) == [new, run.arrived, run.kept]
      assert {:ok, "from the job\n"} = Git.run(repo, ["show", "#{new}:kept.txt"])
      assert {:ok, "from a person\n"} = Git.run(repo, ["show", "#{new}:theirs.txt"])

      # What a person approves is the merged head, recorded by whoever kept it.
      assert {:ok, %{sha: ^new, row: row}} = Forge.Merge.changeset(fresh(ticket))
      assert row.author["id"] == user.id

      user_id = user.id

      assert [%{actor: %{"id" => ^user_id}, payload: payload}] =
               events(ticket, "ticket.work_kept")

      assert %{"merged" => true, "via" => "page", "from" => from, "to" => ^new} = payload
      assert from == run.arrived
      assert payload["job_id"] == run.job.id
    end

    test "a kept commit already on the branch merges nothing", context do
      %{ticket: ticket, user: user, repo: repo} = context
      run = moved_run!(context)
      # Somebody fetched the kept work and pushed it on: the branch now holds it.
      {:ok, _} = Git.run(repo, ["update-ref", "refs/heads/" <> ticket.branch, run.kept])

      assert {:ok, _kept} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert head(repo, ticket) == run.kept

      assert [%{payload: %{"merged" => false, "to" => to}}] = events(ticket, "ticket.work_kept")
      assert to == run.kept
    end

    test "a run with no outcome (a park or a question) runs the state again", context do
      %{ticket: ticket, user: user} = context
      run = moved_run!(context, outcome: nil)

      assert {:ok, kept} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert kept.status == :active
      assert [%{state: "refining", attempt: 2}] = pending(ticket)
    end

    test "a clash is refused naming the paths and the ticket stays stuck with every way out",
         context do
      %{ticket: ticket, user: user, repo: repo} = context

      run =
        moved_run!(context,
          kept: {"same.txt", "the job's"},
          arrived: {"same.txt", "the person's"}
        )

      assert {:error, {:kept_work_conflicts, ["same.txt"]}} =
               Operator.keep_work(fresh(ticket), user, run.job.id)

      assert fresh(ticket).status == :stuck
      assert head(repo, ticket) == run.arrived
      assert events(ticket, "ticket.work_kept") == []
      assert Engine.branch_moved_stop(fresh(ticket))["job_id"] == run.job.id
      assert Artifacts.latest(ticket.id, "changeset") == nil

      # *Run again* is still there, and leaves the kept work unused.
      assert {:ok, again} = Operator.retry(fresh(ticket), user)
      assert again.status == :active
      assert head(repo, ticket) == run.arrived
    end

    test "the guard is asked before any git work: a refused actor merges nothing", context do
      %{ticket: ticket, repo: repo} = context
      run = moved_run!(context)
      before = head(repo, ticket)

      assert {:error, :forbidden} =
               Engine.keep_work(fresh(ticket), {:user, Ecto.UUID.generate()}, run.job.id,
                 allow: fn -> {:error, :forbidden} end
               )

      assert head(repo, ticket) == before
      assert events(ticket, "ticket.work_kept") == []
      assert fresh(ticket).status == :stuck
    end

    test "a second press, and a press on a stop since left, do nothing (stale_stop)", context do
      %{ticket: ticket, user: user} = context
      run = moved_run!(context)

      assert {:error, :stale_stop} = Operator.keep_work(fresh(ticket), user, Ecto.UUID.generate())
      assert {:ok, _} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert {:error, :stale_stop} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert length(events(ticket, "ticket.work_kept")) == 1
    end

    test "after Run again the old stop is stale", context do
      %{ticket: ticket, user: user, repo: repo} = context
      run = moved_run!(context)
      {:ok, _} = Operator.retry(fresh(ticket), user)
      before = head(repo, ticket)

      assert {:error, :stale_stop} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert head(repo, ticket) == before
    end

    test "a stop whose kept commit is not in the repository is refused", context do
      %{ticket: ticket, user: user, repo: repo} = context
      run = moved_run!(context, unkept: true)

      assert {:error, :nothing_kept} = Operator.keep_work(fresh(ticket), user, run.job.id)
      assert head(repo, ticket) == run.arrived
      assert fresh(ticket).status == :stuck
    end

    test "a read token and a member of another project merge nothing", context do
      %{ticket: ticket, repo: repo} = context
      run = moved_run!(context)
      {:ok, _secret, reader} = Tokens.issue(context.project, name: "ro", git: :reader, api: :read)

      {:ok, other_project} =
        register_owned!(%{
          name: "elsewhere-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      stranger = member_fixture(other_project)

      assert {:error, :forbidden} = Operator.keep_work(fresh(ticket), reader, run.job.id)
      assert {:error, :forbidden} = Operator.keep_work(fresh(ticket), stranger, run.job.id)
      assert head(repo, ticket) == run.arrived
      assert events(ticket, "ticket.work_kept") == []
    end

    test "a write token keeps it and is named, through the door it came by", context do
      %{ticket: ticket, project: project} = context
      run = moved_run!(context)
      {:ok, _secret, writer} = Tokens.issue(project, name: "bot", git: :reader, api: :write)

      assert {:ok, _} = Operator.keep_work(fresh(ticket), writer, run.job.id, via: :mcp)

      assert [%{actor: %{"kind" => "api", "name" => "bot"}, payload: %{"via" => "mcp"}}] =
               events(ticket, "ticket.work_kept")
    end
  end
end
