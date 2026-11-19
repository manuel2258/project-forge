defmodule Forge.ExtendTest do
  @moduledoc """
  A person extends a job that ran out of budget (`docs/design/workflow-grammar-v1.md` § Extending
  a job): the same job runs again on its own session, on the room they gave it and the note they
  wrote, and each decision is a record.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, Events, FakeWorker, Jobs, Operator, Repo, Spend, Tickets}
  alias Forge.Jobs.{Extension, Extensions, Job, Run}
  alias Forge.Tickets.{CapRaise, Ticket}
  alias ForgeCore.Workflow.State

  # No edge on `budget_exhausted`: a job that runs out sticks the ticket, which is what a person
  # then extends or restarts. `implementing` declares 12M tokens and 150 turns.
  @workflow """
  version: 1
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md]
      budget: { turns: 150, tokens: 12M }
    reviewing:
      prompt: agents/review.md
      inputs: [implementation.md]
      produces: [review.md]
      budget: { turns: 60, tokens: 600k }
    review_ready: {}
  transitions:
    - { from: implementing, to: reviewing }
    - { from: reviewing, to: review_ready }
  limits:
    ticket_tokens: 100M
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/agents/review.md" => "Review the change.\n"
      })

    {:ok, project} =
      register_owned!(%{name: "extend-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    worker = FakeWorker.connect()

    %{ticket: ticket, user: user, project: project, worker: worker}
  end

  defp pending(ticket) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    job
  end

  # What the worker reports when it uploaded the run's session.
  defp uploaded(assignment),
    do: %{
      "session_id" => "sess-42",
      "session_blob" => assignment["store"]["session_prefix"] <> "1.jsonl",
      "version" => "2.1.284",
      "usage" => 12_000_000
    }

  # A run of the ticket's pending job that runs out of tokens and leaves its session.
  defp run_out(ticket, worker, harness \\ %{}) do
    assignment = ticket |> pending() |> FakeWorker.assign(worker)

    {:ok, job} =
      FakeWorker.finish(assignment, "max_budget",
        written: %{},
        harness: Map.merge(uploaded(assignment), harness)
      )

    {Tickets.get!(ticket.id), Jobs.get!(job.id)}
  end

  defp extend(ticket, user, job, attrs \\ %{}) do
    Operator.extend(ticket, user, job.id, Map.merge(%{"tokens" => "6M", "turns" => "75"}, attrs))
  end

  defp events(ticket, type) do
    ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == type))
  end

  describe "the same job runs again" do
    test "it goes back to pending as the same row and attempt, in a new run, with no transition",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      assert %{status: :stuck} = ticket
      assert %Job{status: :finished, outcome: :budget_exhausted, exhausted: :tokens} = job
      jobs_before = Jobs.for_ticket(ticket.id)
      taken_before = length(events(ticket, "transition.taken"))

      assert {:ok, %Ticket{status: :active}} =
               extend(ticket, user, job, %{"note" => "Finish the review."})

      reopened = Jobs.get!(job.id)
      assert reopened.status == :pending
      assert reopened.attempt == job.attempt
      assert reopened.outcome == nil and reopened.exhausted == nil and reopened.finished_at == nil
      assert reopened.worker_id == nil
      # What it used, its turns and its session are kept.
      assert reopened.usage == job.usage and reopened.turns == job.turns
      assert reopened.harness_session_id == "sess-42"
      assert reopened.session_blob == job.session_blob
      # No new job, no transition: the spec is the one it was made with.
      assert Enum.map(Jobs.for_ticket(ticket.id), & &1.id) == Enum.map(jobs_before, & &1.id)
      assert length(events(ticket, "transition.taken")) == taken_before
      assert reopened.spec == job.spec

      assert [%Extension{tokens: 6_000_000, turns: 75, note: "Finish the review."} = extension] =
               Extensions.all(job.id)

      assert extension.exhausted == :tokens and extension.usage_before == 12_000_000
      assert extension.runs_before == 1 and extension.user_id == user.id

      assert [%{payload: %{"tokens" => 6_000_000, "note" => "Finish the review."}}] =
               events(ticket, "job.extended")
    end

    test "a job may be extended again, and the spec is the same after both", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job)

      {ticket, again} = run_out(ticket, worker)
      assert again.id == job.id and again.status == :finished
      assert {:ok, _} = extend(ticket, user, again, %{"tokens" => "3M", "turns" => "20"})

      assert [%{tokens: 6_000_000}, %{tokens: 3_000_000}] = Extensions.all(job.id)
      assert Jobs.get!(job.id).spec == job.spec
      assert length(Repo.all(from r in Run, where: r.job_id == ^job.id)) == 2
      assert Extensions.number(Extensions.current(job)) == 2
    end

    test "the next run is given the extension's figures, its own session and the note",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish the review."})

      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      assert assignment["resume_session"] == "sess-42"
      assert assignment["fork_session"] == false
      assert assignment["session"]["key"] == job.session_blob["key"]
      budget = assignment["spec"]["budget"]
      assert budget["tokens"] == 6_000_000 and budget["turns"] == 75

      assert %{"note" => "Finish the review.", "tokens" => 6_000_000, "turns" => 75} =
               assignment["spec"]["extension"]

      assert assignment["spec"]["extension"]["number"] == 1
      assert assignment["spec"]["extension"]["exhausted"] == "tokens"
      assert assignment["spec"]["extension"]["used_tokens"] == 12_000_000

      # The run is on the extension, and the job's declared budget is untouched.
      assert [%Run{extension_id: id}] = Enum.filter(Jobs.Runs.for_job(job.id), & &1.extension_id)
      assert id == Extensions.current(job).id
      assert Jobs.get!(job.id).spec["budget"]["tokens"] == 12_000_000
    end

    test "an extended job needs a worker that speaks protocol 12, and no other does", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      assert Jobs.protocol_needs(job)[:extension] == 0

      {:ok, _} = extend(ticket, user, job)
      assert Jobs.protocol_needs(Jobs.get!(job.id))[:extension] == 12
      assert Jobs.protocol(Jobs.get!(job.id)) == 12
    end

    # A Codex run is not bounded by `budget.turns` (`docs/design/codex.md`), so a turn figure sent
    # for one — by the API, which has no form to leave the box off — is not recorded and promises
    # nothing.
    test "turns are ignored for a harness whose runs have no turn ceiling", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      job |> Ecto.Changeset.change(harness: "codex") |> Repo.update!()

      assert {:ok, _} = extend(ticket, user, job, %{"turns" => "75"})
      assert [%{tokens: 6_000_000, turns: nil}] = Extensions.all(job.id)
    end

    test "a turn figure the person left blank is the job's own", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"turns" => ""})

      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["budget"]["turns"] == 150
      assert Extensions.current(job).turns == nil
    end

    test "the run that follows ends the job as that run ends, and the stop stays on the record",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job)

      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      {:ok, done} =
        FakeWorker.finish(assignment, "success",
          doc: "implementation.md",
          harness: %{"usage" => 1_000}
        )

      done = Jobs.get!(done.id)
      assert done.outcome == :converged and done.exhausted == nil
      assert DateTime.compare(done.finished_at, job.finished_at) != :lt
      assert done.usage == job.usage + 1_000
      assert Extensions.current(job).stopped_at == job.finished_at
      assert Extensions.current(job).exhausted == :tokens
      assert %{state: "reviewing"} = Tickets.get!(ticket.id)
    end
  end

  describe "a result of the run before the extension" do
    test "sent again after the reopen changes nothing", context do
      %{ticket: ticket, user: user, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      {:ok, job} =
        FakeWorker.finish(assignment, "max_budget", written: %{}, harness: uploaded(assignment))

      ticket = Tickets.get!(ticket.id)
      {:ok, _} = extend(ticket, user, job)
      usage = Tickets.get!(ticket.id).usage

      # The worker re-sends the result until it is acked: the one for the run that ran out.
      assert {:error, :already_recorded} =
               Jobs.complete(
                 job.id,
                 FakeWorker.result(assignment, "max_budget",
                   written: %{},
                   harness: uploaded(assignment)
                 )
               )

      assert %Job{status: :pending, outcome: nil} = Jobs.get!(job.id)
      assert Tickets.get!(ticket.id).usage == usage
      assert %{status: :active} = Tickets.get!(ticket.id)
    end
  end

  describe "what can be extended" do
    test "a job that ended another way, or whose ticket is not stuck, is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      # Running: not finished.
      assert {:error, {:not_extendable, :not_stuck}} =
               extend(Tickets.get!(ticket.id), user, %{id: assignment["job_id"]})

      {:ok, job} =
        FakeWorker.finish(assignment, "invalid_document",
          doc: "implementation.md",
          harness: uploaded(assignment)
        )

      ticket = Tickets.get!(ticket.id)
      assert %{status: :stuck} = ticket
      assert job.outcome == :error
      assert {:error, {:not_extendable, :not_exhausted}} = extend(ticket, user, job)
      assert Extensions.offer(ticket) == nil
      assert Engine.retryable?(ticket)
      assert Repo.aggregate(Extension, :count) == 0
    end

    test "a run that left no session has no extension, and still a restart", context do
      %{ticket: ticket, user: user, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      {:ok, job} = FakeWorker.finish(assignment, "max_budget", written: %{})
      ticket = Tickets.get!(ticket.id)

      assert %Job{outcome: :budget_exhausted} = job
      assert {:error, {:not_extendable, :no_session}} = extend(ticket, user, job)
      assert Extensions.offer(ticket) == nil
      assert Engine.retryable?(ticket)
    end

    test "a session id with no file is not enough", context do
      %{ticket: ticket, user: user, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      {:ok, job} =
        FakeWorker.finish(assignment, "max_budget",
          written: %{},
          harness: %{"session_id" => "sess-42"}
        )

      assert {:error, {:not_extendable, :no_session}} = extend(Tickets.get!(ticket.id), user, job)
    end

    test "a job that is not the latest attempt of its state is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, ticket} = Engine.retry(ticket, user.id)
      assert %Job{attempt: 2, status: :pending} = pending(ticket)

      # The old job is of a ticket that is no longer stuck, and no longer the latest attempt.
      assert {:error, {:not_extendable, _}} = extend(ticket, user, job)
      {ticket, _second} = run_out(ticket, worker)
      assert {:error, {:not_extendable, :not_the_latest_attempt}} = extend(ticket, user, job)
      assert Extensions.offer(ticket).job_id != job.id
    end

    test "a second extension of a job already running again, and a restart of it, are refused",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job)
      ticket = Tickets.get!(ticket.id)

      assert {:error, {:not_extendable, :not_stuck}} = extend(ticket, user, job)
      assert {:error, {:job_live, "implementing"}} = Engine.retry(ticket, user.id)
      assert length(Extensions.all(job.id)) == 1
    end

    test "an extension after a restart is refused: the job is no longer the state's latest",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, ticket} = Engine.retry(ticket, user.id)
      {ticket, _next} = run_out(ticket, worker)

      assert {:error, {:not_extendable, :not_the_latest_attempt}} = extend(ticket, user, job)
    end

    test "another ticket's job, or no job, is not found, and nothing is written", context do
      %{ticket: ticket, user: user, worker: worker, project: project} = context
      {ticket, _job} = run_out(ticket, worker)

      {:ok, other} = Tickets.admit(project, %{title: "Other", body: "."}, {:user, user.id})
      other_job = pending(other)

      assert {:error, :not_found} = extend(ticket, user, other_job)

      assert {:error, :not_found} =
               Operator.extend(ticket, user, Ecto.UUID.generate(), %{"tokens" => "1M"})

      assert {:error, :not_found} =
               Operator.extend(ticket, user, "not-a-uuid", %{"tokens" => "1M"})

      assert Repo.aggregate(Extension, :count) == 0
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end

    test "a ticket that moved since the page was drawn is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      # Moved on by someone else while the page was open, and stuck there too.
      moved = ticket |> Ecto.Changeset.change(state: "reviewing") |> Repo.update!()

      assert {:error, {:not_extendable, :not_this_state}} = extend(moved, user, job)
      assert Repo.aggregate(Extension, :count) == 0
    end

    test "the offer carries the figures the form is drawn from", context do
      %{ticket: ticket, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      assert %{
               job_id: job_id,
               state: "implementing",
               exhausted: :tokens,
               used_tokens: 12_000_000,
               declared_tokens: 12_000_000,
               declared_turns: 150,
               default_tokens: 6_000_000,
               default_turns: 75,
               bounds_turns: true,
               left: left,
               cap: 100_000_000,
               workflow_cap: 100_000_000
             } = Extensions.offer(ticket)

      assert job_id == job.id
      assert left == 100_000_000 - ticket.usage
      assert Extensions.offer(Tickets.get!(ticket.id) |> Map.put(:status, :active)) == nil
    end

    # Criterion 27: half, rounded up, so an odd figure never starts a box at zero or short.
    test "the boxes start at half the declared figure, rounded up", context do
      %{ticket: ticket, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      spec = put_in(job.spec, ["budget"], %{"turns" => 151, "tokens" => 12_000_001})
      job |> Ecto.Changeset.change(spec: spec) |> Repo.update!()

      assert %{default_turns: 76, default_tokens: 6_000_001} = Extensions.offer(ticket)
    end
  end

  # The guards of `extendable/3` that the act's own lookups make unreachable in practice — the job
  # is read by the ticket's id, a stuck ticket is never in the merge queue — are asked of the
  # function directly, because the offer calls it with whatever job it found and the act's checks are
  # not the offer's.
  describe "extendable/3 on its own" do
    setup context do
      {ticket, job} = run_out(context.ticket, context.worker)
      %{ticket: ticket, job: job, workflow: Tickets.workflow(ticket)}
    end

    test "is ok for the job that ran out", %{ticket: ticket, job: job, workflow: workflow} do
      assert :ok = Extensions.extendable(ticket, job, workflow)
    end

    test "refuses a job that is not finished, though it says budget_exhausted",
         %{ticket: ticket, job: job, workflow: workflow} do
      assert {:error, {:not_extendable, :not_finished}} =
               Extensions.extendable(ticket, %{job | status: :running}, workflow)
    end

    test "refuses another ticket's job", %{ticket: ticket, job: job, workflow: workflow} do
      assert {:error, {:not_extendable, :wrong_ticket}} =
               Extensions.extendable(ticket, %{job | ticket_id: Ecto.UUID.generate()}, workflow)
    end

    test "refuses a command's, whatever it says", %{ticket: ticket, job: job, workflow: workflow} do
      assert {:error, {:not_extendable, :not_a_workflow_job}} =
               Extensions.extendable(ticket, %{job | kind: :command}, workflow)
    end

    test "refuses a state that is not an agent's — a re-pin made it something else",
         %{ticket: ticket, job: job, workflow: workflow} do
      for state <- [
            %State{name: "implementing"},
            %State{name: "implementing", prompt: "p", chat: true}
          ] do
        pinned = %{workflow | states: Map.put(workflow.states, "implementing", state)}

        assert {:error, {:not_extendable, :not_an_agent_state}} =
                 Extensions.extendable(ticket, job, pinned)
      end
    end

    # What Run again would spend, which the forms and the API publish for every ticket, whatever
    # state it rests in: a chat step spends none, so the cap never refuses it.
    test "restart_need is the state's budget for an agent state and nothing for any other",
         %{workflow: workflow} do
      budget = %{tokens: 12_000_000, turns: 150}

      need = fn state ->
        Extensions.restart_need(
          %{workflow | states: Map.put(workflow.states, "implementing", state)},
          "implementing"
        )
      end

      assert need.(%State{name: "implementing", prompt: "p", budget: budget}) == 12_000_000
      assert need.(%State{name: "implementing", prompt: "p", chat: true, budget: budget}) == 0
      assert need.(%State{name: "implementing"}) == 0
    end

    test "refuses a ticket in the merge queue — a row written by hand, as no stuck ticket has one",
         %{ticket: ticket, job: job, workflow: workflow} do
      Repo.insert!(%Forge.MergeQueue.Entry{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        from_state: "implementing",
        to_state: "reviewing",
        edge_outcome: "done"
      })

      assert {:error, {:not_extendable, :queued}} = Extensions.extendable(ticket, job, workflow)
    end

    test "refuses while a job of the state is live, whatever the rows in hand say",
         %{ticket: ticket, job: job, workflow: workflow, user: user} do
      {:ok, _} = extend(ticket, user, job)
      # The row is pending in the database; what was read before is stale.
      stale = %{job | status: :finished, outcome: :budget_exhausted}

      assert {:error, {:job_live, "implementing"}} =
               Extensions.extendable(%{ticket | status: :stuck}, stale, workflow)
    end
  end

  describe "who may" do
    test "a non-member is refused, and nothing is written or reopened", context do
      %{ticket: ticket, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      stranger = Forge.AccountsFixtures.user_fixture()

      assert {:error, :forbidden} = extend(ticket, stranger, job)
      assert {:error, :forbidden} = Operator.retry(ticket, stranger, note: "x")
      assert Repo.aggregate(Extension, :count) == 0
      assert Repo.aggregate(Forge.Tickets.Restart, :count) == 0
      assert %Job{status: :finished} = Jobs.get!(job.id)
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end

    test "the guard is asked inside the transaction, after the ticket is locked", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      # The engine is handed the guard and asks it: a refusing one stops the act with nothing
      # written, whoever called.
      assert {:error, :forbidden} =
               Engine.extend(ticket, job.id, user.id, %{"tokens" => "1M"},
                 allow: fn -> {:error, :forbidden} end
               )

      assert {:error, :forbidden} =
               Engine.retry(ticket, user.id, allow: fn -> {:error, :forbidden} end)

      assert Repo.aggregate(Extension, :count) == 0
      assert Repo.aggregate(Forge.Tickets.Restart, :count) == 0
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end

    test "a write token may, and the record names the token; a read token and a job's may not",
         context do
      %{ticket: ticket, worker: worker, project: project} = context
      {ticket, job} = run_out(ticket, worker)

      {:ok, _secret, reader} =
        Forge.Git.Tokens.issue(project, name: "ci", git: :reader, api: :read)

      {:ok, _secret, writer} =
        Forge.Git.Tokens.issue(project, name: "bot", git: :reader, api: :write)

      assert {:error, :forbidden} = extend(ticket, reader, job)
      assert {:error, :forbidden} = Operator.retry(ticket, reader)

      assert {:ok, _ticket} = extend(ticket, writer, job, %{"note" => "go"})
      [extension] = Extensions.all(job.id)
      assert extension.token_id == writer.id and extension.user_id == nil

      assert [%{actor: %{"kind" => "api", "name" => "bot"}}] = events(ticket, "job.extended")
    end

    test "a person's own record names them", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job)

      assert [%Extension{user_id: user_id, token_id: nil}] = Extensions.all(job.id)
      assert user_id == user.id
      assert [%{actor: %{"kind" => "user", "id" => ^user_id}}] = events(ticket, "job.extended")
    end
  end

  describe "the record" do
    test "refuses a figure the database would, before it gets there" do
      job_id = Ecto.UUID.generate()
      valid = %{job_id: job_id, ticket_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

      assert Extension.changeset(%Extension{}, Map.put(valid, :tokens, 1)).valid?
      refute Extension.changeset(%Extension{}, Map.put(valid, :tokens, 0)).valid?
      refute Extension.changeset(%Extension{}, Map.merge(valid, %{tokens: 1, turns: 0})).valid?

      refute Extension.changeset(%Extension{}, Map.merge(valid, %{tokens: 1, user_id: nil})).valid?

      refute Extension.changeset(
               %Extension{},
               Map.merge(valid, %{tokens: 1, note: String.duplicate("n", 4_001)})
             ).valid?
    end

    test "none of the three tables can be edited or deleted, by anyone", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      leaving(ticket, 4_000_000)
      {:ok, _} = extend(Tickets.get!(ticket.id), user, job, %{"raise" => "2M", "note" => "x"})

      # Another ticket's restart: a state is not run again while its job is reopened.
      {:ok, other} =
        Tickets.admit(context.project, %{title: "Other", body: "."}, {:user, user.id})

      {other, _job} = run_out(other, worker)
      {:ok, _} = Operator.retry(other, user, note: "y")

      for record <- [
            hd(Extensions.all(job.id)),
            Repo.one!(Forge.Tickets.Restart),
            Repo.one!(CapRaise)
          ] do
        assert_raise Postgrex.Error, ~r/append-only/, fn -> Repo.delete!(record) end

        schema = record.__struct__

        assert_raise Postgrex.Error, ~r/append-only/, fn ->
          Repo.update_all(
            from(r in schema,
              where: r.id == ^record.id,
              update: [set: [inserted_at: fragment("now()")]]
            ),
            []
          )
        end
      end
    end
  end

  describe "what is typed" do
    test "each bad figure is refused with the text kept, and nothing is written", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      for bad <- ["", "abc", "0", "-5", "1.5x", nil] do
        assert {:error, {:invalid_tokens, ^bad}} = extend(ticket, user, job, %{"tokens" => bad})
      end

      for bad <- ["0", "-3", "1.5", "abc"] do
        assert {:error, {:invalid_turns, ^bad}} = extend(ticket, user, job, %{"turns" => bad})
      end

      assert {:error, {:note_too_long, 4_001}} =
               extend(ticket, user, job, %{"note" => String.duplicate("n", 4_001)})

      # 2,500 letters written as e and a combining accent are 2,500 graphemes and 5,000
      # codepoints: the limit is the database's, which counts codepoints, and a note it would
      # refuse is refused here, not by a constraint that crashes the act.
      decomposed = String.duplicate("e\u0301", 2_500)

      assert {:error, {:note_too_long, 5_000}} =
               extend(ticket, user, job, %{"note" => decomposed})

      # What the database refuses outright — a NUL byte, bytes that are not UTF-8 — is refused here,
      # not raised from the insert.
      for bad <- ["a\u0000b", <<255, 254>>] do
        assert {:error, {:invalid_note, ^bad}} = extend(ticket, user, job, %{"note" => bad})
      end

      assert {:error, {:invalid_raise, "lots"}} = extend(ticket, user, job, %{"raise" => "lots"})
      assert Repo.aggregate(Extension, :count) == 0
      assert %Job{status: :finished} = Jobs.get!(job.id)
    end

    test "800k, 1.5M and a plain number are amounts, and a note of 4,000 is the longest",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      for {typed, tokens} <- [{"800k", 800_000}, {"1.5M", 1_500_000}, {"2000000", 2_000_000}] do
        assert {:ok, figures} = Extensions.parse(%{"tokens" => typed}, true)
        assert figures.tokens == tokens
      end

      note = String.duplicate("n", 4_000)
      assert {:ok, _} = extend(ticket, user, job, %{"note" => "  " <> note <> "\n"})
      assert [%{note: ^note}] = Extensions.all(job.id)
    end

    test "a blank note is no note, and markup is kept as typed", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "  \n "})
      assert [%{note: nil}] = Extensions.all(job.id)

      {ticket, job} = run_out(Tickets.get!(ticket.id), worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "<b>x</b>\nsecond line"})
      assert [_, %{note: "<b>x</b>\nsecond line"}] = Extensions.all(job.id)
    end

    test "the note is never written to a log", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      log =
        capture_log(fn ->
          {:ok, _} = extend(ticket, user, job, %{"note" => "SECRET-NOTE-TEXT"})
          ticket |> pending() |> FakeWorker.assign(worker)
        end)

      refute log =~ "SECRET-NOTE-TEXT"
    end
  end

  describe "the cap" do
    # A ticket that has spent nearly all of its 100M: 12M on the stopped run, and the rest set on
    # the row, so what is left is exactly what a test says.
    defp leaving(ticket, left) do
      workflow = Tickets.workflow(ticket)
      used = Spend.ticket_cap(ticket, workflow) - left
      ticket |> Ecto.Changeset.change(usage: used) |> Repo.update!()
    end

    test "an extension past what is left is refused, and writes nothing", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)

      assert {:error, {:raise_short, 4_000_000, 2_000_000}} = extend(ticket, user, job)
      assert Repo.aggregate(Extension, :count) == 0
      assert Repo.aggregate(CapRaise, :count) == 0
      assert %Job{status: :finished} = Jobs.get!(job.id)
      assert %{status: :stuck, cap_raise: 0} = Tickets.get!(ticket.id)
    end

    test "a raise below the shortfall is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)

      assert {:error, {:raise_short, 4_000_000, 2_000_000}} =
               extend(ticket, user, job, %{"raise" => "1999999"})

      assert Repo.aggregate(Extension, :count) == 0
    end

    test "a raise that covers the shortfall is taken with the extension, and recorded", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)

      assert {:ok, raised} = extend(ticket, user, job, %{"raise" => "2M"})
      assert raised.cap_raise == 2_000_000
      assert Spend.ticket_cap(raised, Tickets.workflow(raised)) == 102_000_000

      assert [%CapRaise{from_tokens: 100_000_000, to_tokens: 102_000_000} = record] =
               Repo.all(CapRaise)

      assert record.user_id == user.id and record.extension_id == Extensions.current(job).id
      assert record.restart_id == nil

      assert [%{payload: %{"from" => 100_000_000, "to" => 102_000_000}}] =
               events(ticket, "ticket.cap_raised")
    end

    test "a second raise starts from the cap the first one made", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)
      assert {:ok, _} = extend(ticket, user, job, %{"raise" => "2M"})

      # The reopened run runs out again, with 1M of the raised 102M left.
      assignment = Tickets.get!(ticket.id) |> pending() |> FakeWorker.assign(worker)

      {:ok, job} =
        FakeWorker.finish(assignment, "max_budget", written: %{}, harness: uploaded(assignment))

      ticket = leaving(Tickets.get!(ticket.id), 1_000_000)
      assert {:ok, raised} = extend(ticket, user, job, %{"tokens" => "6M", "raise" => "5M"})
      assert raised.cap_raise == 7_000_000

      assert [
               %CapRaise{from_tokens: 100_000_000, to_tokens: 102_000_000},
               %CapRaise{from_tokens: 102_000_000, to_tokens: 107_000_000}
             ] = Enum.sort_by(Repo.all(CapRaise), & &1.from_tokens)

      assert [%{payload: %{"from" => 102_000_000, "to" => 107_000_000}}] =
               events(ticket, "ticket.cap_raised")
               |> Enum.filter(&(&1.payload["to"] == 107_000_000))
    end

    test "a raise nothing needs is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      assert {:error, :raise_not_needed} = extend(ticket, user, job, %{"raise" => "1M"})
      assert {:error, :raise_not_needed} = Operator.retry(ticket, user, raise: "1M")
      assert Repo.aggregate(CapRaise, :count) == 0
      assert %{cap_raise: 0} = Tickets.get!(ticket.id)
    end

    test "the raised figure is the cap every reader uses", context do
      %{ticket: ticket, user: user, worker: worker, project: project} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)
      {:ok, raised} = extend(ticket, user, job, %{"raise" => "2M"})
      workflow = Tickets.workflow(raised)

      assert Spend.ticket_remaining(raised, workflow) == 6_000_000

      # The next run's manifest says what is left of the raised figure.
      assignment = raised |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["budget"]["ticket_left"] == 6_000_000
      assert assignment["spec"]["budget"]["ticket_limit"] == 102_000_000

      # A job ending past the workflow's own cap and under the raised one leaves the ticket going.
      past = Ecto.Changeset.change(Tickets.get!(ticket.id), usage: 101_000_000) |> Repo.update!()
      assert Spend.ticket_remaining(past, workflow) == 1_000_000
      assert Spend.gate(past, workflow) == :ok
      _ = project
    end

    # The stop after a job reads the same cap: a ticket that ends a job past the workflow's own
    # figure and under the raised one is not stuck by it.
    test "a job that ends past the workflow's cap and under the raised one leaves the ticket going",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)
      {:ok, raised} = extend(ticket, user, job, %{"raise" => "2M"})

      assignment = raised |> pending() |> FakeWorker.assign(worker)

      {:ok, _done} =
        FakeWorker.finish(assignment, "success",
          doc: "implementation.md",
          harness: %{"usage" => 5_000_000}
        )

      ticket = Tickets.get!(ticket.id)
      # 96M, plus the 5M this run used: 101M of the workflow's 100M, and under the 102M it is now.
      assert ticket.usage == 101_000_000
      assert %{status: :active, state: "reviewing"} = ticket

      assert [%{state: "reviewing", status: :pending}] =
               Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    end

    test "a re-pin that moves the workflow's cap moves it under the raise", context do
      %{ticket: ticket, user: user, worker: worker, project: project} = context
      {ticket, job} = run_out(ticket, worker)
      ticket = leaving(ticket, 4_000_000)
      {:ok, raised} = extend(ticket, user, job, %{"raise" => "2M"})
      {:ok, _} = Engine.cancel(raised, user.id)
      {:ok, restored} = Engine.restore(Tickets.get!(ticket.id), user.id)

      commit_to_default(project, %{
        ".forge/workflow.yml" => String.replace(@workflow, "100M", "120M")
      })

      {:ok, repinned} = Engine.repin(restored, user.id)

      assert Spend.ticket_cap(repinned, Tickets.workflow(repinned)) == 122_000_000
    end

    test "a restart with nothing left is refused without a raise, and runs with one", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)
      ticket = leaving(ticket, 0)

      assert {:error, {:raise_short, 0, 12_000_000}} = Operator.retry(ticket, user)
      assert {:error, {:raise_short, 0, 12_000_000}} = Operator.retry(ticket, user, raise: "11M")
      assert %{status: :stuck} = Tickets.get!(ticket.id)
      assert Repo.aggregate(Forge.Tickets.Restart, :count) == 0

      assert {:ok, %{status: :active, cap_raise: 12_000_000}} =
               Operator.retry(ticket, user, raise: "12M")

      assert [%CapRaise{restart_id: restart_id, extension_id: nil}] = Repo.all(CapRaise)
      assert is_binary(restart_id)
    end

    test "a restart with some left runs lowered to it", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)
      ticket = leaving(ticket, 5_000_000)

      assert {:ok, _} = Operator.retry(ticket, user)
      assignment = Tickets.get!(ticket.id) |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["budget"]["tokens"] == 5_000_000
      assert assignment["spec"]["budget"]["lowered_by"] == "ticket"
      assert Repo.aggregate(CapRaise, :count) == 0
    end

    test "a restart with some left that is raised runs on the state's whole budget", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)
      ticket = leaving(ticket, 5_000_000)

      assert {:ok, %{cap_raise: 7_000_000}} = Operator.retry(ticket, user, raise: "7M")
      assignment = Tickets.get!(ticket.id) |> pending() |> FakeWorker.assign(worker)

      assert assignment["spec"]["budget"]["tokens"] == 12_000_000
      refute Map.has_key?(assignment["spec"]["budget"], "lowered_by")
      assert [%CapRaise{from_tokens: 100_000_000, to_tokens: 107_000_000}] = Repo.all(CapRaise)
    end
  end

  describe "the day" do
    setup do
      original = Application.get_env(:forge, Spend, [])
      on_exit(fn -> Application.put_env(:forge, Spend, original) end)
      %{original: original}
    end

    test "a day with less left than the extension lowers the run, and the pending job reserves the extension",
         context do
      %{ticket: ticket, user: user, worker: worker, original: original} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job)

      # The pending extended job reserves the 6M it was given, not the 12M it declared.
      Application.put_env(:forge, Spend, Keyword.put(original, :daily_tokens, 10_000_000))
      assert Spend.committed() == Spend.day_total() + 6_000_000

      Application.put_env(
        :forge,
        Spend,
        Keyword.put(original, :daily_tokens, 1_000_000 + Spend.day_total() + 6_000_000)
      )

      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["budget"]["tokens"] == 1_000_000
      assert assignment["spec"]["budget"]["declared"] == 6_000_000
      assert assignment["spec"]["budget"]["lowered_by"] == "day"

      assert [%{payload: %{"spec_tokens" => 6_000_000, "binding" => "day"}}] =
               events(ticket, "job.budget_lowered")
    end
  end

  describe "what an extension leaves alone, and what it clears" do
    test "a pending approval is cleared, as running a state again clears it", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)

      pending = %{
        "from" => "implementing",
        "to" => "reviewing",
        "outcome" => "done",
        "approve" => []
      }

      ticket = ticket |> Ecto.Changeset.change(pending_transition: pending) |> Repo.update!()
      assert {:ok, %{pending_transition: nil, status: :active}} = extend(ticket, user, job)
    end

    test "the credential is picked again from the pool: one revoked since the stop is not used",
         context do
      %{ticket: ticket, user: user, worker: worker, project: project} = context
      {ticket, job} = run_out(ticket, worker)
      stopped_on = Jobs.get!(job.id).credential_id
      assert is_binary(stopped_on)

      other = pool!(project, credential_fixture(user))

      {:ok, _revoked} =
        Forge.Credentials.revoke(
          Repo.get!(Forge.Credentials.Credential, stopped_on)
          |> then(&Repo.get!(Forge.Accounts.User, &1.user_id)),
          stopped_on
        )

      {:ok, _} = extend(ticket, user, job)

      FakeWorker.assign(pending(Tickets.get!(ticket.id)), worker)
      assert Jobs.get!(job.id).credential_id == other.id
    end
  end

  describe "a session that cannot be restored" do
    test "the run starts cold, still told of the extension, and records that it did", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish."})

      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["resume_session"] == "sess-42"
      {:ok, _} = FakeWorker.finish(assignment, "no_start")

      # Re-queued without its session, and its run says it did not resume.
      assert %Job{status: :pending, harness_session_id: nil} = Jobs.get!(job.id)
      # The run that never got going lets go of the extension, so the cold one that follows is the
      # extension's first and is told as it would have been.
      assert [%Run{resumed: false, extension_id: nil}] =
               Enum.filter(Jobs.Runs.for_job(job.id), &(&1.resumed == false))

      second = ticket |> pending() |> FakeWorker.assign(worker)
      assert second["resume_session"] == nil
      assert second["spec"]["extension"]["note"] == "Finish."
      assert second["spec"]["extension"]["later_run"] == false
      assert second["spec"]["budget"]["tokens"] == 6_000_000

      extension = Extensions.current(job.id)
      runs = Jobs.Runs.for_job(job.id)
      assert length(runs) == 3
      assert [%Run{finished_at: nil}] = Enum.filter(runs, &(&1.extension_id == extension.id))
    end

    # A run the platform loses before it reported — its machine went away — never delivered the
    # extension's note, so the run that replaces it is the first and is told, and is the one stamped.
    test "a run lost before it reported lets go of the extension, so the next is told", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish."})

      lost = ticket |> pending() |> FakeWorker.assign(worker)
      assert lost["spec"]["extension"]["later_run"] == false
      {:ok, _} = Jobs.requeue(job.id, :worker_lost)

      next = Tickets.get!(ticket.id) |> pending() |> FakeWorker.assign(worker)
      assert next["spec"]["extension"]["later_run"] == false
      assert next["spec"]["extension"]["note"] == "Finish."

      extension_id = Extensions.current(job.id).id
      runs = Jobs.Runs.for_job(job.id)
      assert [%Run{finished_at: nil}] = Enum.filter(runs, &(&1.extension_id == extension_id))
    end

    test "so does a run recovered after its machine was destroyed", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish."})
      ticket |> pending() |> FakeWorker.assign(worker)

      Repo.update_all(from(w in Forge.Workers.Worker, where: w.id == ^worker.id),
        set: [status: :destroyed]
      )

      assert Jobs.recover() >= 1
      extension_id = Extensions.current(job.id).id
      assert Enum.all?(Jobs.Runs.for_job(job.id), &(&1.extension_id != extension_id))
      assert Extensions.to_tell(Jobs.get!(job.id)).id == extension_id
    end

    test "so does a run whose machine was gone when it was sent, and one that hibernated",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish."})
      extension_id = Extensions.current(job.id).id

      stamped = fn ->
        Enum.count(Jobs.Runs.for_job(job.id), &(&1.extension_id == extension_id))
      end

      # Sent to a machine that is no longer there: the run was opened, and never reached anyone.
      Registry.unregister(Forge.Workers.Registry, worker.id)
      assert {:error, :not_connected} = Jobs.assign(pending(Tickets.get!(ticket.id)), worker)
      assert %Job{status: :pending} = Jobs.get!(job.id)
      assert stamped.() == 0
      assert Extensions.to_tell(Jobs.get!(job.id)).id == extension_id

      # A machine that stopped under the run and said so.
      other = FakeWorker.connect()
      assignment = Tickets.get!(ticket.id) |> pending() |> FakeWorker.assign(other)
      assert stamped.() == 1
      {:ok, _} = Jobs.hibernate(assignment["job_id"], nil, "worker stopped")
      assert stamped.() == 0
      assert Extensions.to_tell(Jobs.get!(job.id)).id == extension_id
    end

    # A run after the one the extension was given to — here the job went back to pending as a
    # question or a limit sends it — keeps the extension's ceiling and is not stamped with it, so it
    # is not told it ran out of budget and the job page does not call it the extension's.
    test "a later run of the job keeps the ceiling, and is neither told nor labelled", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      {:ok, _} = extend(ticket, user, job, %{"note" => "Finish."})

      first = ticket |> pending() |> FakeWorker.assign(worker)
      assert first["spec"]["extension"]["later_run"] == false
      extension_id = Extensions.current(job.id).id
      assert [_] = Enum.filter(Jobs.Runs.for_job(job.id), &(&1.extension_id == extension_id))

      # Back to pending with its session, the run closed: what a limit or an answer does.
      Repo.update_all(from(r in Run, where: r.job_id == ^job.id and is_nil(r.finished_at)),
        set: [finished_at: DateTime.utc_now()]
      )

      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: :pending])

      later = ticket |> pending() |> FakeWorker.assign(worker)
      assert later["spec"]["extension"]["later_run"] == true
      assert later["spec"]["budget"]["tokens"] == 6_000_000
      assert later["resume_session"] == "sess-42"

      runs = Jobs.Runs.for_job(job.id)
      assert length(runs) == 3
      assert [%Run{finished_at: finished}] = Enum.filter(runs, &(&1.extension_id == extension_id))
      assert finished != nil

      assert [%Run{finished_at: nil}] =
               Enum.filter(runs, &(is_nil(&1.extension_id) and is_nil(&1.finished_at)))
    end

    test "what the worker says of a run lands on it, and silence leaves it unknown", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job} = run_out(ticket, worker)
      assert [%Run{resumed: nil}] = Jobs.Runs.for_job(job.id)

      {:ok, _} = extend(ticket, user, job)
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      {:ok, _} =
        FakeWorker.finish(assignment, "max_budget",
          written: %{},
          harness: Map.put(uploaded(assignment), "resumed", true)
        )

      assert [%Run{resumed: true}] = Enum.filter(Jobs.Runs.for_job(job.id), &(&1.resumed == true))

      {ticket, job} = {Tickets.get!(ticket.id), Jobs.get!(job.id)}
      {:ok, _} = extend(ticket, user, job)
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      {:ok, _} =
        FakeWorker.finish(assignment, "max_budget",
          written: %{},
          harness: Map.put(uploaded(assignment), "resumed", false)
        )

      assert [%Run{resumed: false}] =
               Enum.filter(Jobs.Runs.for_job(job.id), &(&1.resumed == false))
    end
  end

  describe "restarting" do
    test "the note is the new attempt's arrival comment, after a rejection's", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)

      assert {:ok, _} = Operator.retry(ticket, user, note: "Start smaller.")
      next = Tickets.get!(ticket.id) |> pending()
      assert next.attempt == 2
      assert Jobs.spec(next).entered["comment"] == "Start smaller."
      assert Jobs.spec(next).entered["by"] == "person"
      assert next.restart_id != nil

      assert [%{payload: %{"note" => "Start smaller.", "state" => "implementing"} = payload}] =
               events(ticket, "ticket.retried")

      assert payload["restart_id"] == next.restart_id
    end

    test "a second restart's note follows what the arrival already said", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)
      {:ok, _} = Operator.retry(ticket, user, note: "First.")
      {ticket, _job} = run_out(Tickets.get!(ticket.id), worker)
      {:ok, _} = Operator.retry(ticket, user, note: "Second.")

      assert Jobs.spec(pending(Tickets.get!(ticket.id))).entered["comment"] == "First.\n\nSecond."
    end

    test "a restart on a ticket on hold carries its note and its record to the release",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)

      {:ok, held} = Operator.hold(ticket, user)
      {:ok, retried} = Operator.retry(held, user, note: "After the freeze.")
      assert Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending)) == []
      assert retried.held_entry["restart_id"] != nil

      {:ok, _} = Operator.release(retried, user)
      next = pending(Tickets.get!(ticket.id))
      assert next.attempt == 2
      assert [%{id: restart_id}] = Repo.all(Forge.Tickets.Restart)
      assert next.restart_id == restart_id
      assert Jobs.spec(next).entered["comment"] == "After the freeze."
    end

    test "a second restart on a ticket on hold is refused, and the first one's note is kept",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)

      {:ok, held} = Operator.hold(ticket, user)
      {:ok, retried} = Operator.retry(held, user, note: "A")

      assert {:error, {:job_live, "implementing"}} = Operator.retry(retried, user, note: "B")
      assert [%{note: "A"}] = Repo.all(Forge.Tickets.Restart)

      {:ok, _} = Operator.release(Tickets.get!(ticket.id), user)
      assert Jobs.spec(pending(Tickets.get!(ticket.id))).entered["comment"] == "A"
    end

    # *Stop now* leaves an entry for the state, which is not a Run again waiting: running the state
    # again over it is allowed, and its note reaches the release.
    test "Run again after Stop now on a hold is taken, with its note", context do
      %{ticket: ticket, user: user, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, stopped} = Operator.stop_now(held, user)
      assert stopped.held_entry["state"] == "implementing"
      refute Map.get(stopped.held_entry, "restart_id")
      {:ok, _} = Jobs.hibernate(assignment["job_id"], nil, "cancelled")

      assert {:ok, retried} = Operator.retry(Tickets.get!(ticket.id), user, note: "Smaller steps")
      assert retried.held_entry["restart_id"] != nil

      {:ok, _} = Operator.release(Tickets.get!(ticket.id), user)
      assert Jobs.spec(pending(Tickets.get!(ticket.id))).entered["comment"] == "Smaller steps"
    end

    test "a restart without a note is as it was, and records itself", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)
      assert {:ok, _} = Operator.retry(ticket, user)

      next = Tickets.get!(ticket.id) |> pending()
      assert Jobs.spec(next).entered == nil
      assert [%{note: nil, state: "implementing"}] = Repo.all(Forge.Tickets.Restart)
      assert next.resume_from_id == nil
    end

    test "a note over the limit, or a raise that is not an amount, is refused", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, _job} = run_out(ticket, worker)

      assert {:error, {:note_too_long, 4_001}} =
               Operator.retry(ticket, user, note: String.duplicate("n", 4_001))

      assert {:error, {:note_too_long, 5_000}} =
               Operator.retry(ticket, user, note: String.duplicate("e\u0301", 2_500))

      for bad <- ["a\u0000b", <<255, 254>>] do
        assert {:error, {:invalid_note, ^bad}} = Operator.retry(ticket, user, note: bad)
      end

      assert {:error, {:invalid_raise, "x"}} = Operator.retry(ticket, user, raise: "x")
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end
  end

  describe "the spec it was made with" do
    test "a re-pin since the stop does not change what the reopened job is told", context do
      %{ticket: ticket, user: user, worker: worker, project: project} = context
      {ticket, job} = run_out(ticket, worker)

      commit_to_default(project, %{".forge/agents/implement.md" => "A completely new prompt.\n"})
      {:ok, repinned} = Engine.repin(ticket, user.id)
      assert repinned.workflow_commit != ticket.workflow_commit

      {:ok, _} = extend(repinned, user, job)
      assignment = repinned |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["prompt"] == job.spec["prompt"]
      assert assignment["spec"]["commit"] == job.spec["commit"]
      refute assignment["spec"]["prompt"] =~ "completely new"
    end
  end
end
