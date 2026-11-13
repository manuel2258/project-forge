defmodule Forge.CodexRenewalTest do
  @moduledoc """
  What a run hands back of its ChatGPT login (`docs/design/credentials.md` § A login comes back).

  One test per condition of acceptance, each broken in turn: only the holder, on its own worker, while
  its run is live, of a kind that comes back, sealed for this job, of the right shape, naming the
  same account. A refusal keeps the stored login and says why; neither touches the job.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Events, FakeWorker, Jobs, Repo}
  alias Forge.Credentials.Credential

  @marker "MARKER-never-in-an-event"

  defp login(account, refresh) do
    claims =
      Base.url_encode64(~s({"https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}),
        padding: false
      )

    Jason.encode!(%{
      "tokens" => %{
        "id_token" => "h.#{claims}.s",
        "access_token" => "at-#{@marker}",
        "refresh_token" => refresh,
        "account_id" => account
      }
    })
  end

  setup do
    config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(config, :data_dir, tmp_dir("codex-renewal"))
    )

    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    name = "renew#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    owner = member_fixture(project, :admin)
    worker = FakeWorker.connect(harness: "codex", project: project)
    other = FakeWorker.connect(harness: "codex", project: project)
    funded!(project)

    credential =
      credential_fixture(owner, %{
        harness: "codex",
        kind: "chatgpt_login",
        secret: login("acct-1", "rt-old")
      })

    Repo.update_all(from(c in Credential, where: c.id == ^credential.id),
      set: [account_id: "acct-1"]
    )

    pool!(project, credential)
    {:ok, chat} = Conversations.open(project, "hello", harness: "codex")
    {:ok, _} = Jobs.assign(chat, worker)

    %{
      project: project,
      worker: worker,
      other: other,
      credential: credential,
      chat: Jobs.get!(chat.id)
    }
  end

  defp seal(login, worker, job, purpose \\ :return),
    do: ForgeCore.Job.Credential.seal(login, worker.token_hash, job.id, purpose)

  defp turn(chat, return) do
    Conversations.record_turn(chat, %{
      "turn" => System.unique_integer([:positive]),
      "harness" => %{"session_id" => "s", "turns" => 1, "credential_return" => return}
    })
  end

  defp stored(credential) do
    sealed = Repo.one(from c in Credential, where: c.id == ^credential.id, select: c.secret)
    {:ok, %{"token" => text}} = Credential.open(sealed)
    text
  end

  defp events(type), do: Repo.all(from e in Events.Event, where: e.type == ^type, order_by: e.seq)

  defp refused(ctx, return, reason) do
    before = stored(ctx.credential)
    seen = length(events("credential.renewal_refused"))
    assert {:ok, _chat} = turn(ctx.chat, return)

    # The stored login is kept, whatever came back, and exactly one refusal says why.
    assert stored(ctx.credential) == before
    assert length(events("credential.renewal_refused")) == seen + 1
    payload = events("credential.renewal_refused") |> List.last() |> Map.fetch!(:payload)
    assert payload["reason"] == reason
    assert payload["job_id"] == ctx.chat.id
    refute inspect(payload) =~ @marker
    assert events("credential.renewed") == []
  end

  test "a login its holder hands back is kept, sealed again, and recorded without its content",
       ctx do
    renewed = login("acct-1", "rt-new")
    assert {:ok, chat} = turn(ctx.chat, seal(renewed, ctx.worker, ctx.chat))

    assert stored(ctx.credential) == renewed
    assert Repo.get!(Credential, ctx.credential.id).renewed_at != nil
    assert [%{payload: payload}] = events("credential.renewed")
    assert payload == %{"credential_id" => ctx.credential.id, "job_id" => ctx.chat.id}
    assert events("credential.renewal_refused") == []
    # The turn itself was recorded all the same.
    assert chat.turns == 1
  end

  test "and the next job is given what was handed back", ctx do
    renewed = login("acct-1", "rt-new")
    {:ok, _} = turn(ctx.chat, seal(renewed, ctx.worker, ctx.chat))
    Jobs.requeue(ctx.chat.id, :worker_lost)

    {:ok, next} = Conversations.open(ctx.project, "again", harness: "codex")
    {:ok, _} = Jobs.assign(next, ctx.other)

    assert {:ok, %{"sealed" => sealed}} =
             Forge.Credentials.for_wire(ctx.credential, ctx.other, next.id)

    assert {:ok, ^renewed} = ForgeCore.Job.Credential.open(sealed, ctx.other.token_hash, next.id)
  end

  test "another account's login is refused", ctx do
    refused(ctx, seal(login("acct-2", "rt-x"), ctx.worker, ctx.chat), "names a different account")
  end

  test "a login another worker sealed is refused", ctx do
    refused(
      ctx,
      seal(login("acct-1", "rt-x"), ctx.other, ctx.chat),
      "not sealed by the job's worker for this job"
    )
  end

  test "a login sealed for another job, or as a delivery, is refused", ctx do
    {:ok, elsewhere} = Conversations.open(ctx.project, "else", harness: "codex")
    text = login("acct-1", "rt-x")

    refused(ctx, seal(text, ctx.worker, elsewhere), "not sealed by the job's worker for this job")

    refused(
      ctx,
      seal(text, ctx.worker, ctx.chat, :credential),
      "not sealed by the job's worker for this job"
    )
  end

  # A revoke erases the secret. A run that was holding the login when it happened must not put a
  # live one back, and the event must not say it was renewed.
  test "a login handed back after its credential was revoked is not put back", ctx do
    {:ok, _} =
      Forge.Credentials.revoke(
        Repo.get!(Forge.Accounts.User, ctx.credential.user_id),
        ctx.credential.id
      )

    renewed = login("acct-1", "rt-after-revoke")

    assert {:ok, _chat} = turn(ctx.chat, seal(renewed, ctx.worker, ctx.chat))

    row = Repo.get!(Credential, ctx.credential.id)
    assert row.secret == nil
    assert row.renewed_at == nil
    assert events("credential.renewed") == []

    assert [%{payload: %{"reason" => "the credential was revoked"}}] =
             events("credential.renewal_refused")
  end

  test "something that is not a login is refused", ctx do
    refused(
      ctx,
      seal("not json #{@marker}", ctx.worker, ctx.chat),
      "not a login of the right shape"
    )
  end

  test "one from a run on another worker than the job's is refused", ctx do
    Repo.update_all(from(j in Jobs.Job, where: j.id == ^ctx.chat.id),
      set: [worker_id: ctx.other.id]
    )

    chat = Jobs.get!(ctx.chat.id)
    before = stored(ctx.credential)

    assert {:ok, _} = turn(chat, seal(login("acct-1", "rt-x"), ctx.other, chat))
    assert stored(ctx.credential) == before

    assert [%{payload: %{"reason" => "the run is not on the job's worker"}}] =
             events("credential.renewal_refused")
  end

  test "one that arrives after its run ended is refused", ctx do
    Jobs.requeue(ctx.chat.id, :worker_lost)
    before = stored(ctx.credential)

    assert {:ok, _} = turn(ctx.chat, seal(login("acct-1", "rt-x"), ctx.worker, ctx.chat))
    assert stored(ctx.credential) == before

    assert [%{payload: %{"reason" => "the job has no live run on a credential"}}] =
             events("credential.renewal_refused")
  end

  test "a kind that does not come back ignores what a run hands back", ctx do
    Jobs.requeue(ctx.chat.id, :worker_lost)
    owner = Repo.get!(Forge.Accounts.User, ctx.credential.user_id)

    token =
      pool!(
        ctx.project,
        credential_fixture(owner, %{harness: "codex", kind: "access_token", secret: "tok-1"})
      )

    # Only the token is left to take, so the job runs on a kind that does not come back.
    Repo.update_all(from(c in Credential, where: c.id == ^ctx.credential.id),
      set: [revoked_at: DateTime.utc_now(:second)]
    )

    {:ok, other_chat} = Conversations.open(ctx.project, "x", harness: "codex")
    {:ok, _} = Jobs.assign(other_chat, ctx.other)
    assert Jobs.get!(other_chat.id).credential_id == token.id

    assert {:ok, _} =
             turn(Jobs.get!(other_chat.id), seal(login("acct-1", "rt-x"), ctx.other, other_chat))

    assert [%{payload: %{"reason" => "this kind of credential does not come back"}}] =
             events("credential.renewal_refused")

    assert stored(token) == "tok-1"
  end

  # A pending workflow job whose state names Codex, the chat having let go of the login first.
  defp codex_workflow_job(ctx) do
    yaml =
      "../../../core/test/fixtures/workflow_example.yml"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace("    env: refine\n", "    env: refine\n    harness: codex\n",
        global: false
      )

    codex_job(ctx, %{".forge/workflow.yml" => yaml})
  end

  # A state that may invoke a command, so that its run can park.
  @parking """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    implementing:
      prompt: agents/implement.md
      harness: codex
      produces: [implementation.md]
      may_invoke:
        build: { max: 2 }
      budget: { turns: 20, tokens: 400k }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits:
    ticket_tokens: 5M
  """

  defp codex_parking_job(ctx) do
    codex_job(ctx, %{
      ".forge/workflow.yml" => @parking,
      ".forge/commands/build.sh" => "#!/bin/sh\nexit 0\n"
    })
  end

  defp codex_job(ctx, files) do
    Jobs.requeue(ctx.chat.id, :worker_lost)
    bare = seeded_repo(files)

    project =
      Forge.Repo.update!(Forge.Projects.Project.changeset(ctx.project, %{repo_path: bare}))

    {:ok, ticket} = Forge.Tickets.admit(project, %{title: "x"}, {:user, ctx.credential.user_id})
    [job] = Jobs.for_ticket(ticket.id)
    assert job.harness == "codex"
    {:ok, job}
  end

  # The three result paths of a workflow job carry the same step: this is the one that finishes.
  test "a workflow job's result hands one back too", ctx do
    {:ok, job} = codex_workflow_job(ctx)

    assignment = FakeWorker.assign(job, ctx.worker)
    renewed = login("acct-1", "rt-from-a-workflow-job")

    sealed = seal(renewed, ctx.worker, job)

    {:ok, _} =
      FakeWorker.finish(assignment, "success",
        doc: "refinement.md",
        harness: %{"credential_return" => sealed}
      )

    assert stored(ctx.credential) == renewed
    assert [%{payload: %{"job_id" => job_id}}] = events("credential.renewed")
    assert job_id == job.id
    refute_leaked(sealed)
  end

  # **The returned login is sealed under a key derived from the worker's token hash, which is in
  # this database**: only the Vault's re-sealed copy may hold it. No event, which the API serves
  # to members, may.
  defp refute_leaked(sealed) do
    for event <- Repo.all(Events.Event), do: refute(inspect(event.payload) =~ sealed)
  end

  test "a run stopped by its account's limit hands its login back and keeps it out of events",
       ctx do
    {:ok, job} = codex_workflow_job(ctx)
    renewed = login("acct-1", "rt-from-a-limit")
    sealed = seal(renewed, ctx.worker, job)

    {:ok, _} =
      FakeWorker.run(job, ctx.worker, "rate_limited", harness: %{"credential_return" => sealed})

    assert [_] = events("job.rate_limited")
    assert stored(ctx.credential) == renewed
    refute_leaked(sealed)
  end

  test "a run that parks for its commands hands its login back and keeps it out of events",
       ctx do
    {:ok, job} = codex_parking_job(ctx)
    assignment = FakeWorker.assign(job, ctx.worker)
    renewed = login("acct-1", "rt-from-a-park")
    sealed = seal(renewed, ctx.worker, job)

    {:ok, _} =
      FakeWorker.park(assignment, [%{"command" => "build", "args" => []}],
        harness: %{"credential_return" => sealed}
      )

    assert [_] = events("job.parked")
    assert stored(ctx.credential) == renewed
    refute_leaked(sealed)
  end

  test "a resume that never got going still hands back a login it refreshed", ctx do
    {:ok, job} = codex_workflow_job(ctx)

    {:ok, job} =
      Repo.update(Forge.Jobs.Job.progress_changeset(job, %{harness_session_id: "stale-session"}))

    assignment = FakeWorker.assign(job, ctx.worker)
    renewed = login("acct-1", "rt-from-a-failed-resume")
    sealed = seal(renewed, ctx.worker, job)

    {:ok, again} =
      FakeWorker.finish(assignment, "no_start", harness: %{"credential_return" => sealed})

    assert again.status == :pending
    assert [_] = events("job.resume_failed")
    assert stored(ctx.credential) == renewed
    refute_leaked(sealed)
  end

  test "a run that hibernates hands its refreshed login back with the report", ctx do
    {:ok, workflow_job} = codex_workflow_job(ctx)
    FakeWorker.assign(workflow_job, ctx.worker)
    renewed = login("acct-1", "rt-from-a-hibernation")

    assert {:ok, _} =
             Jobs.hibernate(workflow_job.id, "abc", "memory", %{
               "harness" => %{"credential_return" => seal(renewed, ctx.worker, workflow_job)}
             })

    assert stored(ctx.credential) == renewed
    assert [%{payload: %{"job_id" => job_id}}] = events("credential.renewed")
    assert job_id == workflow_job.id
  end

  # The platform's answer to a conversation stopped for reaching its token budget: dormant, its
  # session kept so a reopen resumes it, and a login the last turn refreshed is kept with the report.
  test "a chat that ends on its token budget goes dormant and hands its login back", ctx do
    renewed = login("acct-1", "rt-at-the-end")

    assert {:ok, chat} =
             Conversations.ended(ctx.chat, "abc", "token budget reached",
               result: %{
                 "status" => "finished",
                 "harness" => %{"credential_return" => seal(renewed, ctx.worker, ctx.chat)}
               }
             )

    assert chat.status == :hibernated
    assert stored(ctx.credential) == renewed
    assert [%{payload: %{"reason" => "token budget reached"}}] = events("chat.ended")
  end

  test "a turn that hands nothing back records neither", ctx do
    assert {:ok, _} = turn(ctx.chat, nil)
    assert events("credential.renewed") == []
    assert events("credential.renewal_refused") == []
  end
end
