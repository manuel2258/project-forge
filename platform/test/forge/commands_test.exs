defmodule Forge.CommandsTest do
  @moduledoc """
  Commands on the platform, end to end against the fake worker (`docs/design/commands.md`): a
  command state running its batch and deciding its outcome from the exit statuses, and an agent
  that invokes, parks, and resumes with what came back.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, FakeWorker, Jobs, Storage, Tickets, Workers}
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job
  alias ForgeCore.Job.Spec

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      env: build
      produces: build.log
      timeout: 20m
      resources: { memory: 4GiB, cpu: 4 }
    test:
      run: .forge/commands/test.sh
      timeout: 30m
    lint:
      run: .forge/commands/test.sh
      timeout: 5m
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket, build.log]
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 2 }
        test: { max: 2, concurrent: 1 }
      budget: { turns: 20, cost: 2.00 }
    checking:
      invoke: [build, [test, --all]]
      exit: { 0: done, "*": checks_failed }
    review_ready: {}
  transitions:
    - { from: implementing, to: checking }
    - { from: checking, to: review_ready }
    - { from: checking, to: implementing, when: checks_failed, max: 3 }
  limits:
    ticket_cost: 25.00
  """

  @build "#!/bin/sh\nexec make \"$@\"\n"

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/build.sh" => @build,
        ".forge/commands/test.sh" => "#!/bin/sh\nexec make test \"$@\"\n"
      })

    {:ok, project} =
      register_owned!(%{name: "cmd-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    %{project: project, ticket: ticket, user: user, worker: FakeWorker.connect(), repo: repo}
  end

  defp pending(ticket, kind \\ :workflow)

  defp pending(ticket, :workflow),
    do: ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))

  defp pending(ticket, :command),
    do: ticket.id |> Jobs.commands_for_ticket() |> Enum.filter(&(&1.status == :pending))

  # A command state runs its commands again, as a batch of its own: the retry is the state's, and
  # a command state's work is its commands. Without this branch a retry marked the ticket active,
  # recorded itself, and made nothing to run.
  test "a command state is run again as a new batch", %{user: user} = context do
    ticket = implement(context)
    assert ticket.state == "checking"
    first = pending(ticket, :command)
    assert length(first) == 2

    for job <- first do
      job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Repo.update!()
    end

    {:ok, stuck} = Engine.stick(Tickets.get!(ticket.id), "the batch was lost")
    assert Engine.retryable?(stuck)

    {:ok, _ticket} = Engine.retry(stuck, user.id)

    again = pending(ticket, :command)
    assert length(again) == 2
    assert Enum.map(again, & &1.id) -- Enum.map(first, & &1.id) == Enum.map(again, & &1.id)

    assert ticket.id
           |> Events.for_ticket()
           |> Enum.count(&(&1.type == "commands.started")) == 2
  end

  # The commands an agent invokes share its state's name and number their own attempts, so the
  # agent's previous attempt is found by kind as well as by number: a second attempt reading what
  # changed since the first would find two rows at attempt 1, the agent and the build it ran.
  # Both attempts are given a changeset input here, as a state after the first may read one.
  test "an agent that invoked commands is the previous attempt its next one reads", context do
    [first] = pending(context.ticket)
    assignment = FakeWorker.assign(first, context.worker)
    {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])

    [build] = pending(context.ticket, :command)
    assert %Job{state: "implementing", attempt: 1} = build
    {:ok, _job} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _job} = FakeWorker.run(Jobs.get!(first.id), context.worker, "success", written: written)

    checks = context.ticket |> pending(:command) |> Enum.sort_by(& &1.attempt)

    for {job, status} <- Enum.zip(checks, [0, 1]) do
      {:ok, _job} = job |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(status)
    end

    [second] = pending(context.ticket)
    assert %Job{state: "implementing", attempt: 2} = second

    seen = String.duplicate("a", 40)
    reads_changeset!(Jobs.get!(first.id), seen)
    second = reads_changeset!(second, String.duplicate("b", 40))

    spec = second |> FakeWorker.assign(context.worker) |> Map.fetch!("spec") |> Spec.from_map()
    assert spec.previous_changeset == seen
  end

  defp reads_changeset!(job, sha) do
    input = %{"name" => "changeset", "version" => sha, "content" => ""}

    job
    |> Ecto.Changeset.change(spec: Map.update!(job.spec, "inputs", &[input | &1]))
    |> Repo.update!()
  end

  defp head(repo, ticket) do
    {:ok, sha} = Forge.Git.resolve(repo, "refs/heads/" <> ticket.branch)
    sha
  end

  defp implement(%{ticket: ticket, worker: worker}) do
    [job] = pending(ticket)
    written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
    {:ok, _job} = FakeWorker.run(job, worker, "success", written: written)
    Tickets.get!(ticket.id)
  end

  # What `FakeWorker.park/3` sends, sent again as the worker re-sends an unacked result.
  defp parked_again(invocations) do
    %ForgeCore.Job.Result{
      status: :parked,
      invocations: invocations,
      harness: %{"session_id" => "sess-42", "turns" => 3, "cost_usd" => 0.5}
    }
  end

  describe "a command state" do
    test "runs its batch at the branch head, with the script from the pinned commit", context do
      ticket = implement(context)
      assert ticket.state == "checking"

      assert [build, test] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)
      spec = Jobs.spec(build)

      assert %Spec{kind: :command, state: "checking", env: "build"} = spec
      assert spec.command["name"] == "build"
      assert spec.command["script"] == @build
      assert spec.command["at"] == head(context.repo, ticket)
      assert spec.command["timeout_ms"] == 1_200_000
      assert Jobs.spec(test).command["args"] == ["--all"]
      assert build.parent_job_id == nil
      assert spec.command["batch"] == Jobs.spec(test).command["batch"]

      # The command's own resources, then the state's, then the platform's (§ Resources).
      assert build.memory_max == 4 * 1024 ** 3 and build.cores == 4
      assert test.memory_max == Workers.slice_bytes()
    end

    # The rule the pinned read exists for: an agent cannot change what the command it is judged
    # by does, by editing the script on its branch.
    test "runs the script from the pinned commit, not the one the agent edited", context do
      [job] = pending(context.ticket)
      assignment = FakeWorker.assign(job, context.worker)
      FakeWorker.commit(assignment, ".forge/commands/build.sh", "#!/bin/sh\nexit 0\n")

      written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
      {:ok, _job} = FakeWorker.finish(assignment, "success", written: written)

      ticket = Tickets.get!(context.ticket.id)
      [build | _] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)
      assert Jobs.spec(build).command["script"] == @build
      assert Jobs.spec(build).command["at"] == head(context.repo, ticket)
    end

    test "is assigned with a read-only token, a key for its log, and no credential", context do
      ticket = implement(context)
      [build | _] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)

      assignment = FakeWorker.assign(build, context.worker)

      assert assignment["kind"] == "command"
      assert assignment["spec"]["command"]["name"] == "build"
      refute Map.has_key?(assignment, "credential")
      refute Map.has_key?(assignment, "backlog")
      assert String.starts_with?(assignment["store"]["log_key"], "job/#{build.id}/")
      # A script runs no harness, so it has no session to upload.
      refute Map.has_key?(assignment["store"], "session_prefix")

      assert :ok =
               Storage.Token.verify(
                 assignment["store"]["log_token"],
                 :put,
                 assignment["store"]["log_key"]
               )

      project = Forge.Projects.get!(ticket.project_id)
      assert {:ok, token} = Tokens.authorise(assignment["git"]["token"], project, :read)
      refute token.write
      assert :error = Tokens.authorise(assignment["git"]["token"], project, :write)

      assert %Job{status: :running, credential_id: nil} = Jobs.get!(build.id)
    end

    test "decides its outcome once the last command is done, first non-zero status first",
         context do
      ticket = implement(context)
      [build, test] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)

      build_run = FakeWorker.assign(build, context.worker)
      test_run = FakeWorker.assign(test, context.worker)

      # The second command fails first; nothing is decided while the first is still running.
      {:ok, _job} = FakeWorker.finish_command(test_run, 2)
      assert Tickets.get!(ticket.id).state == "checking"

      {:ok, _job} = FakeWorker.finish_command(build_run, 0, log: "compiled\n")
      ticket = Tickets.get!(ticket.id)

      assert ticket.state == "implementing"

      assert [%{type: "commands.decided", payload: payload}] =
               ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "commands.decided"))

      assert payload["statuses"] == [0, 2]
      assert payload["outcome"] == "checks_failed"

      # The engine's transition out of the command state carries what sent it back.
      [again] = pending(ticket)
      assert Jobs.spec(again).entered["outcome"] == "checks_failed"
      assert Jobs.get!(test.id).exit_status == 2

      # The log is the artifact its command produces, a blob in the store.
      version = Artifacts.latest(ticket.id, "build.log")
      assert "store:job/" <> _rest = version.blob_uri
      assert {:ok, "compiled\n"} = Artifacts.content(version)
    end

    test "passes when every command exits zero", context do
      ticket = implement(context)

      for job <- pending(ticket, :command) do
        {:ok, _job} = job |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      end

      assert Tickets.get!(ticket.id).state == "review_ready"
    end

    test "a command that ended with no status fails the batch", context do
      ticket = implement(context)
      [build, test] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)

      {:ok, _job} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      {:ok, _job} = test |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(nil)

      assert Tickets.get!(ticket.id).state == "implementing"
    end

    # A worker that could not run it at all reports a failure; the batch is decided all the same.
    test "a command the worker failed is a command with no status", context do
      ticket = implement(context)
      [build, test] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)

      {:ok, _job} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      FakeWorker.assign(test, context.worker)
      {:ok, _job} = Jobs.fail(test.id, {:not_a_commit, "x"})

      assert Tickets.get!(ticket.id).state == "implementing"
    end

    test "a log under another job's key is not recorded as this one's", context do
      ticket = implement(context)
      [build | _] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)
      assignment = FakeWorker.assign(build, context.worker)

      {:ok, _info} = Storage.put("job/elsewhere/log.txt", "not yours")
      {:ok, _job} = FakeWorker.finish_command(assignment, 0, log_key: "job/elsewhere/log.txt")

      assert Artifacts.latest(ticket.id, "build.log") == nil
    end

    test "is live work: a person cannot move the ticket on from under it", context do
      ticket = implement(context)

      assert {:error, {:job_live, "checking"}} =
               Engine.choose(ticket, context.user.id, "review_ready")
    end
  end

  # `docs/design/job-prompt.md` § How the job arrived: the job a failed batch sends the ticket to
  # is the one that has to fix it, and the outcome's name is not the reason — the log is.
  describe "the job a command state sends the ticket to" do
    # One loop of implementing and a failing `checking`, each batch's logs saying which loop it was.
    # `build_log` stands in for the build's, and `between` runs once the build has finished.
    defp fail_checks(context, loop, build_log \\ nil, between \\ fn _build -> :ok end) do
      ticket = implement(context)
      [build, test] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)

      {:ok, build} =
        build
        |> FakeWorker.assign(context.worker)
        |> FakeWorker.finish_command(0, log: build_log || "built #{loop}\n")

      between.(build)

      {:ok, _job} =
        test
        |> FakeWorker.assign(context.worker)
        |> FakeWorker.finish_command(2, log: "failed #{loop}\n")

      Tickets.get!(ticket.id)
    end

    test "is handed what its commands said, and their logs", context do
      ticket = fail_checks(context, 1)
      assert ticket.state == "implementing"

      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, context.worker)
      spec = Spec.from_map(assignment["spec"])

      assert %{"from" => "checking", "outcome" => "checks_failed", "batch" => batch} =
               spec.entered

      assert is_binary(batch)

      assert [
               %{"command" => "build", "exit_status" => 0, "log" => "entered-1-build.log"},
               %{
                 "command" => "test",
                 "args" => ["--all"],
                 "exit_status" => 2,
                 "log" => "entered-2-test.log"
               }
             ] = spec.entered_commands

      # Not a resume: nothing of its own ran.
      assert spec.command_results == []

      assert [
               %{"file" => "entered-1-build.log"},
               %{"file" => "entered-2-test.log", "key" => key, "token" => token}
             ] = assignment["commands"]

      assert :ok = Storage.Token.verify(token, :get, key)
      assert {:ok, "failed 1\n"} = Storage.get(key)
    end

    # `workflow-grammar-v1.md` § Inputs: a state may name a command's log, and reads the latest
    # version the ticket has — absent until the command has run, then inlined like a document.
    test "reads the command's log when it names it as an input", context do
      [first] = pending(context.ticket)
      first_spec = Jobs.spec(first)
      assert "build.log" in first_spec.absent_inputs
      refute Enum.any?(first_spec.inputs, &(&1.name == "build.log"))

      ticket = fail_checks(context, 1)
      [job] = pending(ticket)

      assert %{version: 1, content: "built 1\n"} =
               Enum.find(Jobs.spec(job).inputs, &(&1.name == "build.log"))

      refute "build.log" in Jobs.spec(job).absent_inputs
    end

    # Inlined into the spec, so a runaway build is cut to its two ends rather than copied into
    # every later job's spec whole.
    test "reads a log too long to inline as its two ends", context do
      log = "BEGIN\n" <> String.duplicate("compiling a file\n", 20_000) <> "END\n"
      assert byte_size(log) > 256 * 1024

      ticket = fail_checks(context, 1, log)
      [job] = pending(ticket)
      %{content: content} = Enum.find(Jobs.spec(job).inputs, &(&1.name == "build.log"))

      assert String.starts_with?(content, "BEGIN\n")
      assert String.ends_with?(content, "END\n")
      assert content =~ "bytes cut, of #{byte_size(log)}"
      assert byte_size(content) < 256 * 1024 + 100
    end

    # An input that names a log is always optional, so one the store cannot give back is absent
    # rather than the reason the next job cannot be made.
    test "a log the store no longer has is an absent input", context do
      ticket =
        fail_checks(context, 1, nil, fn build ->
          %{blob_uri: uri} = Artifacts.latest(build.ticket_id, "build.log")
          {:ok, key} = Storage.key_from_uri(uri)
          :ok = Storage.delete(key)
        end)

      [job] = pending(ticket)
      assert "build.log" in Jobs.spec(job).absent_inputs
      refute Enum.any?(Jobs.spec(job).inputs, &(&1.name == "build.log"))
    end

    # The ticket this was built for was stuck on an exhausted `max`, and the edge back was taken by
    # a person twice. Those jobs are the ones that most need the log.
    test "is handed the latest batch when a person moves a stuck ticket on", context do
      stuck = Enum.reduce(1..4, nil, fn loop, _ticket -> fail_checks(context, loop) end)
      assert %{state: "checking", status: :stuck} = stuck

      {:ok, _ticket} = Engine.choose(stuck, context.user.id, "implementing")
      [job] = pending(stuck)
      assignment = FakeWorker.assign(job, context.worker)
      spec = Spec.from_map(assignment["spec"])

      assert %{"by" => "person", "batch" => _batch} = spec.entered
      assert [_build, %{"exit_status" => 2}] = spec.entered_commands

      [_build, %{"key" => key}] = assignment["commands"]
      assert {:ok, "failed 4\n"} = Storage.get(key)
    end

    # A batch nothing decided describes a visit that did not end the way the ticket left; handing
    # it over would give the job a reason that is not the one it is there for.
    test "is handed nothing from a batch that was never decided", %{user: user} = context do
      ticket = implement(context)

      for job <- pending(ticket, :command) do
        job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Repo.update!()
      end

      {:ok, stuck} = Engine.stick(Tickets.get!(ticket.id), "the batch was lost")
      {:ok, _ticket} = Engine.choose(stuck, user.id, "implementing")

      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, context.worker)
      spec = Spec.from_map(assignment["spec"])

      refute Map.has_key?(spec.entered, "batch")
      assert spec.entered_commands == []
      refute Map.has_key?(assignment, "commands")
    end
  end

  describe "an agent that invokes" do
    setup context do
      [job] = pending(context.ticket)
      %{job: job, assignment: FakeWorker.assign(job, context.worker)}
    end

    test "parks on what its grant allows and is told why the rest was refused", context do
      %{assignment: assignment, job: job} = context
      at = head(context.repo, context.ticket)

      {:ok, parked} =
        FakeWorker.park(assignment, [
          %{"command" => "build", "args" => ["--release"]},
          %{"command" => "build", "args" => []},
          %{"command" => "build", "args" => []},
          %{"command" => "deploy", "args" => []}
        ])

      assert parked.status == :parked
      assert parked.harness_session_id == "sess-42"
      assert Workers.remaining(context.worker) == Workers.get!(context.worker.id).memory_budget

      children = pending(context.ticket, :command) |> Enum.sort_by(& &1.attempt)
      assert [%Job{parent_job_id: parent, state: "implementing"}, _second] = children
      assert parent == job.id
      assert Enum.all?(children, &(Jobs.spec(&1).command["at"] == at))

      assert %{payload: %{"invocations" => entries}} =
               job.id |> Events.for_job() |> Enum.find(&(&1.type == "job.parked"))

      assert [%{"job_id" => _}, %{"job_id" => _}, third, fourth] = entries
      assert third["refused"] == "no invocations of `build` remain: 2 were allowed"
      assert fourth["refused"] == "`deploy` is not a command this state may run"

      # Parked is live: the ticket cannot be moved on from under it.
      assert Jobs.live?(context.ticket.id, "implementing")
    end

    test "resumes once its commands are done, with their results and logs", context do
      %{assignment: assignment, job: job} = context

      {:ok, _parked} =
        FakeWorker.park(assignment, [
          %{"command" => "build", "args" => ["--release"]},
          %{"command" => "test", "args" => []},
          %{"command" => "deploy", "args" => []}
        ])

      [build, test] = pending(context.ticket, :command) |> Enum.sort_by(& &1.attempt)
      {:ok, _job} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      assert Jobs.get!(job.id).status == :parked

      {:ok, _job} = test |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(1)
      assert Jobs.get!(job.id).status == :pending

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      assert resumed["resume_session"] == "sess-42"

      spec = Spec.from_map(resumed["spec"])

      assert [
               %{
                 "command" => "build",
                 "args" => ["--release"],
                 "exit_status" => 0,
                 "log" => "1-build.log"
               },
               %{
                 "command" => "test",
                 "exit_status" => 1,
                 "outcome" => "converged",
                 "log" => "2-test.log"
               },
               %{"command" => "deploy", "refused" => "`deploy` is not" <> _}
             ] = spec.command_results

      assert spec.may_invoke["build"]["remaining"] == 1
      assert spec.may_invoke["test"]["remaining"] == 1

      assert [
               %{"file" => "1-build.log", "key" => build_key, "token" => build_token},
               %{"file" => "2-test.log"}
             ] = resumed["commands"]

      assert :ok = Storage.Token.verify(build_token, :get, build_key)

      assert {:ok, "ran " <> _} = Storage.get(build_key)
    end

    test "with nothing it may run, goes straight back with only the refusals", context do
      %{assignment: assignment, job: job} = context

      {:ok, back} =
        FakeWorker.park(assignment, [], invocation_error: "invoke.json is not valid JSON")

      assert back.status == :pending
      assert pending(context.ticket, :command) == []

      spec =
        context.worker
        |> then(&FakeWorker.assign(Jobs.get!(job.id), &1))
        |> Map.fetch!("spec")
        |> Spec.from_map()

      assert [%{"command" => "invoke.json", "refused" => "invoke.json is not valid JSON"}] =
               spec.command_results
    end

    # Declared in `commands`, and not granted to this state: refused all the same.
    test "is refused a command its state was not granted", context do
      {:ok, _parked} = FakeWorker.park(context.assignment, [%{"command" => "lint", "args" => []}])

      assert pending(context.ticket, :command) == []

      assert %{payload: %{"invocations" => [%{"refused" => refused}]}} =
               context.job.id |> Events.for_job() |> Enum.find(&(&1.type == "job.parked"))

      assert refused == "`lint` is not a command this state may run"
    end

    # `max` is over the job's life, not per park.
    test "counts its invocations across parks", context do
      %{assignment: assignment, job: job} = context
      two = [%{"command" => "build", "args" => []}, %{"command" => "build", "args" => []}]
      {:ok, _parked} = FakeWorker.park(assignment, two)

      for build <- pending(context.ticket, :command) do
        {:ok, _} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      end

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      {:ok, back} = FakeWorker.park(resumed, [%{"command" => "build", "args" => []}])

      assert back.status == :pending
      assert pending(context.ticket, :command) == []
    end

    # The commit the worker pushed and reported, not whatever the branch says by the time the
    # platform reads it.
    test "runs its commands at the commit it reported", context do
      reported = head(context.repo, context.ticket)
      FakeWorker.commit(context.assignment, "later.txt", "moved on\n")
      refute head(context.repo, context.ticket) == reported

      {:ok, _parked} =
        FakeWorker.park(context.assignment, [%{"command" => "build", "args" => []}],
          commit: reported
        )

      [build] = pending(context.ticket, :command)
      assert Jobs.spec(build).command["at"] == reported
    end

    # Its commands finished, and nothing has followed them up yet: only the park keeps it live.
    test "is live while parked, with no command of its own still live", context do
      {:ok, _parked} =
        FakeWorker.park(context.assignment, [%{"command" => "build", "args" => []}])

      Enum.each(pending(context.ticket, :command), &finished_without_follow_up/1)

      assert Jobs.get!(context.job.id).status == :parked
      assert Jobs.live?(context.ticket.id, "implementing")
    end

    # The worker re-sends a result until it is acked, and an ack can be lost after the commit.
    test "a parked result heard twice parks once", context do
      %{assignment: assignment, job: job} = context
      invocations = [%{"command" => "build", "args" => []}]
      {:ok, _parked} = FakeWorker.park(assignment, invocations)
      cost = Tickets.get!(context.ticket.id).cost_usd

      assert {:error, :already_recorded} = Jobs.complete(job.id, parked_again(invocations))

      assert [_one] = pending(context.ticket, :command)
      assert Tickets.get!(context.ticket.id).cost_usd == cost
      assert 1 == job.id |> Events.for_job() |> Enum.count(&(&1.type == "job.parked"))
    end

    # Not by status: a park with nothing to run has put the job back to pending already.
    test "a park with nothing to run, heard twice, is counted once", context do
      %{assignment: assignment, job: job} = context
      {:ok, back} = FakeWorker.park(assignment, [], invocation_error: "not JSON")
      assert back.status == :pending
      cost = Tickets.get!(context.ticket.id).cost_usd

      assert {:error, :already_recorded} = Jobs.complete(job.id, parked_again([]))
      assert Tickets.get!(context.ticket.id).cost_usd == cost
    end

    # A later run parks again, and is heard.
    test "a job that ran again may park again", context do
      %{assignment: assignment, job: job} = context
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      [build] = pending(context.ticket, :command)
      {:ok, _} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      {:ok, parked} = FakeWorker.park(resumed, [%{"command" => "build", "args" => []}])
      assert parked.status == :parked
    end

    # Parked on this batch, not merely parked: batch one's command, reported finished again, must
    # not wake a parent that has since parked on batch two with batch one's results.
    test "an old batch's command does not wake a parent parked on a new one", context do
      %{assignment: assignment, job: job} = context
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      [first] = pending(context.ticket, :command)
      {:ok, first} = first |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      {:ok, _parked} = FakeWorker.park(resumed, [%{"command" => "build", "args" => []}])
      assert Jobs.get!(job.id).status == :parked

      Forge.Jobs.Commands.follow_up(first)
      assert Jobs.get!(job.id).status == :parked
    end

    # They share its state, and count their own.
    test "its commands do not take its attempt numbers", context do
      %{assignment: assignment, job: job} = context

      {:ok, _parked} =
        FakeWorker.park(assignment, [
          %{"command" => "build", "args" => []},
          %{"command" => "test", "args" => []}
        ])

      for command <- pending(context.ticket, :command) do
        {:ok, _} = command |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)
      end

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      written = %{"implementation.md" => "---\noutcome: done\n---\n# Done\n"}
      {:ok, _} = FakeWorker.finish(resumed, "success", written: written)

      # Checking passes on a zero, and review_ready is not a job state: send it back instead.
      ticket = Tickets.get!(context.ticket.id)

      for command <- pending(ticket, :command) do
        {:ok, _} = command |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(1)
      end

      assert [%Job{state: "implementing", attempt: 2}] = pending(Tickets.get!(ticket.id))
    end

    # The results of one batch belong to the resume after it, not to every run after that.
    test "a later resume is not handed an old batch's results", context do
      %{assignment: assignment, job: job} = context
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      [build] = pending(context.ticket, :command)
      {:ok, _job} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

      resumed = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      assert [_one] = Spec.from_map(resumed["spec"]).command_results

      {:ok, _} = FakeWorker.finish(resumed, "blocking", doc: "implementation.md")
      {:ok, _} = Jobs.resume(Jobs.get!(job.id))

      again = FakeWorker.assign(Jobs.get!(job.id), context.worker)
      assert Spec.from_map(again["spec"]).command_results == []
      refute Map.has_key?(again, "commands")
    end
  end

  # `docs/design/commands.md` § Worker pools: a release from before commands would run one as an
  # agent job.
  describe "the gate" do
    test "gives commands, and jobs that may invoke, only to a worker that speaks protocol 2" do
      old = %Forge.Workers.Worker{protocol: 1}
      new = %Forge.Workers.Worker{protocol: 2}
      silent = %Forge.Workers.Worker{protocol: nil}

      refute Workers.speaks?(old, 2)
      assert Workers.speaks?(new, 2)
      refute Workers.speaks?(silent, 2)
      assert Workers.speaks?(old, 0) and Workers.speaks?(silent, 0)
    end

    # A command needs the protocol commands arrived in; a workflow job needs the one questions as
    # a headline and a sentence arrived in, because its release teaches and corrects the block.
    # A conversation needs 8, the one that squashes a merge it left open: it is told the default
    # branch, and a release that acts on that without 8's squash loses every turn after the merge
    # (`worker-channel.md` § Versions).
    #
    # Its archive is the largest of these for a workflow job and a conversation, which is why the
    # reasons are read apart (`Jobs.protocol_needs/1`): the whole would say 9 for both.
    test "asks a command for protocol 2, a workflow job 3 and a conversation 8", context do
      [job] = pending(context.ticket)
      assert Jobs.protocol_needs(job)[:kind] == 3

      ticket = implement(context)
      [build | _] = pending(ticket, :command)
      assert Jobs.protocol(build) == 2
      assert Jobs.harness(build) == nil

      assert Jobs.protocol_needs(%Job{kind: :chat})[:kind] == 8
    end

    # A command has no archive folder, so a worker without one may run it; the others need 9
    # (`docs/design/archive.md` § The worker's side).
    test "asks a workflow job and a conversation for protocol 9, and a command for nothing of it",
         context do
      [job] = pending(context.ticket)
      assert Jobs.protocol(job) == 9
      assert Jobs.protocol(%Job{kind: :chat}) == 9
      assert Jobs.protocol_needs(job)[:archive] == 9

      [build | _] = pending(implement(context), :command)
      assert Jobs.protocol_needs(build)[:archive] == 0
    end

    # The scheduler's own demand: a protocol 2 release serving the project is not handed an agent,
    # whose result it would report in a shape this platform refuses to record.
    test "the scheduler does not hand an agent to a protocol 2 release", context do
      [job] = pending(context.ticket)
      _old = FakeWorker.connect(protocol: 2, project: context.project)
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0
      assert Jobs.get!(job.id).status == :pending
    end

    # `docs/design/archive.md`: a release from before the archive would start the job without the
    # folder its prompt describes, so the scheduler gives it neither a workflow job nor a chat.
    test "the scheduler does not hand an agent to a protocol 8 release, which has no archive",
         context do
      [job] = pending(context.ticket)
      _old = FakeWorker.connect(protocol: 8, project: context.project)
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0
      assert Jobs.get!(job.id).status == :pending
    end

    test "a worker of protocol 2 is not given an agent, and still is given a command", context do
      [job] = pending(context.ticket)
      old = Workers.get!(FakeWorker.connect(protocol: 2, project: context.project).id)
      new = Workers.get!(FakeWorker.connect(protocol: 9, project: context.project).id)
      agent = %{kind: :workflow, memory: 1, cores: 1, project_id: context.project.id}
      agent = Map.put(agent, :protocol, Jobs.protocol(job))

      refute Workers.fits?(old, agent)
      assert Workers.fits?(new, agent)
      assert Workers.fits?(old, %{agent | kind: :command, protocol: 2})
    end

    # The scheduler's own demand, not one built by hand: an older release serving the project is
    # not handed the command — nor waited on, since it could never take it.
    test "the scheduler does not hand a command to an older release", context do
      ticket = implement(context)
      _old = FakeWorker.connect(protocol: 1, project: context.project)
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0
      assert Enum.all?(Jobs.commands_for_ticket(ticket.id), &(&1.status == :pending))
      assert Tickets.get!(ticket.id).status == :stuck
    end

    test "a worker of an older protocol is not given a command", context do
      old = FakeWorker.connect(protocol: 1, project: context.project)
      new = FakeWorker.connect(protocol: 2, project: context.project)
      demand = %{kind: :command, memory: 1, cores: 1, project_id: context.project.id, protocol: 2}

      refute Workers.fits?(Workers.get!(old.id), demand)
      assert Workers.fits?(Workers.get!(new.id), demand)
    end
  end

  # `docs/design/commands.md` § Limits: `concurrent` is the scheduler's to hold.
  test "concurrent holds an invoking job to its number of one command in flight", context do
    worker = FakeWorker.connect(project: context.project)
    [job] = pending(context.ticket)
    assignment = FakeWorker.assign(job, worker)

    {:ok, _parked} =
      FakeWorker.park(assignment, [
        %{"command" => "test", "args" => ["a"]},
        %{"command" => "test", "args" => ["b"]}
      ])

    start_supervised!(Forge.Jobs.Scheduler)
    assert Forge.Jobs.Scheduler.tick() == 1

    assert [waiting] = pending(context.ticket, :command)
    assert Jobs.running_commands(job.id, "test") == 1
    assert Jobs.running_commands(job.id, "build") == 0
    assert Jobs.current_wait(waiting).payload["reason"] == "concurrent"

    # Once the first is done the second goes.
    [running] =
      context.ticket.id |> Jobs.commands_for_ticket() |> Enum.filter(&(&1.status == :running))

    running_assignment = FakeWorker.take_assignment(running.id)
    {:ok, _job} = FakeWorker.finish_command(running_assignment, 0)
    assert Forge.Jobs.Scheduler.tick() == 1
    assert pending(context.ticket, :command) == []
  end

  test "a failure reported after the result changes nothing", context do
    ticket = implement(context)
    [build | _] = pending(ticket, :command) |> Enum.sort_by(& &1.attempt)
    {:ok, build} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

    assert {:error, :already_recorded} = Jobs.fail(build.id, {:worker, "late"})
    assert %Job{outcome: :converged, exit_status: 0} = Jobs.get!(build.id)
  end

  # A command's result commits before its follow-up runs; a node that went down between the two
  # left the batch done and nothing to act on it.
  describe "on boot" do
    test "a parent whose commands finished while nothing followed them up is resumed", context do
      [job] = pending(context.ticket)
      assignment = FakeWorker.assign(job, context.worker)
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      [build] = pending(context.ticket, :command)
      finished_without_follow_up(build)

      assert Jobs.get!(job.id).status == :parked
      assert Forge.Jobs.Commands.recover() == 1
      assert Jobs.get!(job.id).status == :pending
    end

    test "a command state whose batch finished while nothing decided it is decided", context do
      ticket = implement(context)
      Enum.each(pending(ticket, :command), &finished_without_follow_up/1)

      assert Tickets.get!(ticket.id).state == "checking"
      assert Forge.Jobs.Commands.recover() == 1
      assert Tickets.get!(ticket.id).state == "review_ready"
    end

    # Sent back to an active state, so only the state the ticket is in tells this batch from an
    # owed one.
    test "leaves alone a batch that was followed up", context do
      ticket = implement(context)

      for command <- pending(ticket, :command) do
        {:ok, _} = command |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(1)
      end

      assert %{state: "implementing", status: :active} = Tickets.get!(ticket.id)
      assert Forge.Jobs.Commands.recover() == 0
    end
  end

  defp finished_without_follow_up(job) do
    {:ok, _job} =
      job
      |> Job.progress_changeset(%{status: :finished, outcome: :converged, exit_status: 0})
      |> Forge.Repo.update()
  end

  # What a redelivered or doubled follow-up must not do: decide a command state's batch twice, or
  # resume a parked job twice. Each is what the lock and the recorded decision are for.
  describe "a follow-up that arrives twice" do
    test "decides a command state's batch once", context do
      ticket = implement(context)

      jobs =
        for job <- pending(ticket, :command) do
          {:ok, job} = job |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(1)
          job
        end

      Forge.Jobs.Commands.follow_up(List.last(jobs))

      decided = ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "commands.decided"))
      assert length(decided) == 1
      assert [_one] = pending(Tickets.get!(ticket.id))
    end

    test "resumes a parked job once", context do
      [job] = pending(context.ticket)
      assignment = FakeWorker.assign(job, context.worker)
      {:ok, _parked} = FakeWorker.park(assignment, [%{"command" => "build", "args" => []}])
      [build] = pending(context.ticket, :command)
      {:ok, build} = build |> FakeWorker.assign(context.worker) |> FakeWorker.finish_command(0)

      Forge.Jobs.Commands.follow_up(build)

      resumed = job.id |> Events.for_job() |> Enum.filter(&(&1.type == "job.resumed"))
      assert length(resumed) == 1
    end
  end
end
