defmodule Forge.MergeFixtures do
  @moduledoc """
  A ticket at the edge of its merge, and the moves around one, for the tests that merge: one
  copy of what six test files each carried their own of.
  """

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, Repo}

  @doc "Records `sha` as the ticket's next `changeset` version — by `job` when one is given."
  def changeset!(ticket, sha, job \\ nil) do
    author = if job, do: {:job, job.id}, else: :system

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, author, %{blob_uri: "git:" <> sha})

    :ok
  end

  @doc """
  Records `text` as the ticket's next `commit-message` version and returns its number. What the
  merge commit will say; a merge with none is refused.
  """
  def commit_message!(ticket, text \\ "Land the change\n\nWhat it was for.\n") do
    {:ok, %{version: version}} =
      Artifacts.record_version(ticket.id, "commit-message", :document, :system, %{content: text})

    version
  end

  @doc """
  The same for a conversation: in the scope that name is written in, which for this one is always
  the conversation's own even on a ticket — asked of `Forge.Conversations.document_scope/2` with
  the name, because asking without it writes a ticket chat's into the ticket's scope and the
  merge would never find it.
  """
  def chat_commit_message!(chat, text \\ "Land the conversation's work\n") do
    name = ForgeCore.Workflow.commit_message_artifact()
    scope = Forge.Conversations.document_scope(chat, name)

    {:ok, %{version: version}} =
      Artifacts.record_version(scope, name, :document, {:job, chat.id}, %{content: text})

    version
  end

  @doc """
  The state the workflow leaves a ticket in just before the merge: resting in `review_ready`,
  active, with the approval of `changeset` into `merged` pending.
  """
  def pend_merge(ticket) do
    ticket
    |> Ecto.Changeset.change(
      state: "review_ready",
      status: :active,
      pending_transition: %{
        "from" => "review_ready",
        "to" => "merged",
        "outcome" => nil,
        "approve" => ["changeset"]
      }
    )
    |> Repo.update!()
  end

  @doc """
  What an integrating job does, by the bare repository's own path and with the authority of the
  platform's own push, as `Forge.GitFixtures.commit_to/4` stands in for it: merge the default
  branch into the ticket's, resolve README.md, commit the merge and push. Returns the new head.
  The worker's side of this is `ForgeWorker.Job.WorkspaceTest`'s.
  """
  def integrate!(bare, ticket) do
    work = Path.join(Forge.GitFixtures.tmp_dir("integrate"), "work")
    {_out, 0} = git(Path.dirname(work), ["clone", "-q", "--branch", ticket.branch, bare, work])
    {_out, 1} = git(work, ["merge", "-q", "origin/main"])
    File.write!(Path.join(work, "README.md"), "both versions\n")
    {_out, 0} = git(work, ["commit", "-qam", "merge main"])
    {_out, 0} = git(work, ["push", "-q", "origin", "HEAD:refs/heads/" <> ticket.branch])
    {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
    head
  end

  @doc """
  git in a scratch clone, as a job's agent would run it, pushing with the platform's own
  authority. Returns `{output, status}`.
  """
  def git(dir, args) do
    Forge.Git.spawn_cmd(
      "git",
      ["-c", "user.name=job", "-c", "user.email=job@forge", "-c", "commit.gpgsign=false" | args],
      cd: dir,
      env: [{"FORGE_INTERNAL", "1"}],
      stderr_to_stdout: true
    )
  end

  @doc """
  The ticket's latest integrating job ends `done` having resolved nothing — its changeset is what
  it was — and the engine decides what follows, as after any job's result.
  """
  def integration_done!(ticket) do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> Enum.filter(&(&1.state == "integrating"))
      |> List.last()
      |> Ecto.Changeset.change(status: :finished, outcome: :converged, declared_outcome: "done")
      |> Repo.update!()

    {:ok, ticket} = Engine.after_job(ticket, job, "done")
    ticket
  end

  @jump_workflow """
  version: 1
  initial: refining
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 10, tokens: 100k }
    planning:
      prompt: agents/plan.md
      inputs: [ticket, refinement.md]
      produces: [plan.md]
      budget: { turns: 10, tokens: 100k }
    implementing:
      prompt: agents/implement.md
      inputs: [plan.md, notes.md]
      produces: [implementation.md, changeset, commit-message]
      outcomes: [done, again]
      budget: { turns: 10, tokens: 100k }
    review_ready:
      produces: [notes.md]
    chatting:
      chat: true
      prompt: agents/chat.md
      inputs: [plan.md]
      produces: [chat-notes.md]
      outcomes: [done]
    merged:
      on_enter: merge
      on_conflict: integrating
    integrating:
      prompt: agents/integrate.md
      inputs: [changeset]
      produces: [changeset]
      budget: { turns: 10, tokens: 100k }
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: planning, to: implementing }
    - { from: implementing, to: review_ready }
    - { from: implementing, to: implementing, when: again, max: 1 }
    - { from: review_ready, to: merged, approve: [changeset] }
    - { from: review_ready, to: implementing }
    - { from: integrating, to: review_ready }
    - { from: review_ready, to: chatting }
    - { from: chatting, to: review_ready }
  limits:
    ticket_tokens: 5M
  """

  @doc """
  A workflow whose states are mostly *not* reached by an edge from one another, which is what a
  jump is for: `refining → planning` approves a document, `planning` has no edge to `review_ready`
  and `merged` has no edge from `implementing`. `implementing` reads `plan.md`, which is required
  (every way in passes through `planning`), and `notes.md`, which is not. With `queue: true` the
  edge into `merged` is declared to queue.
  """
  def jump_workflow(opts \\ []) do
    if Keyword.get(opts, :queue, false),
      do:
        String.replace(
          @jump_workflow,
          "{ from: review_ready, to: merged, approve: [changeset] }",
          "{ from: review_ready, to: merged, approve: [changeset], queue: true }"
        ),
      else: @jump_workflow
  end

  @doc "The files of a repository holding `jump_workflow/1` and the prompts it names."
  def jump_files(opts \\ []) do
    %{
      ".forge/workflow.yml" => jump_workflow(opts),
      ".forge/agents/refine.md" => "refine\n",
      ".forge/agents/plan.md" => "plan\n",
      ".forge/agents/implement.md" => "implement\n",
      ".forge/agents/chat.md" => "chat\n",
      ".forge/agents/integrate.md" => "integrate\n"
    }
  end

  @doc "The ticket's events of `type`, oldest first."
  def events_of(ticket, type),
    do: ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == type))

  @doc "The payload of the ticket's latest event of `type`."
  def latest_payload(ticket, type),
    do: ticket |> events_of(type) |> List.last() |> Map.fetch!(:payload)
end
