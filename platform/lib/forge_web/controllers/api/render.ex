defmodule ForgeWeb.Api.Render do
  @moduledoc "Plain maps for API responses. One function per shape; nothing clever."

  alias Forge.Artifacts.{Artifact, Question, Version}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket

  # No `repo_path`: it is an absolute path on the platform's host and nothing outside the
  # platform needs it — a worker reaches a repository by git URL, not by server-side path.
  def project(%Project{} = p) do
    %{
      id: p.id,
      name: p.name,
      default_branch: p.default_branch,
      inserted_at: p.inserted_at
    }
  end

  def ticket(%Ticket{} = t, project_name) do
    %{
      id: t.id,
      ref: "#{project_name}##{t.number}",
      project: project_name,
      number: t.number,
      title: t.title,
      body: t.body,
      state: t.state,
      status: t.status,
      cost_usd: Decimal.to_string(t.cost_usd),
      branch: t.branch,
      base_commit: t.base_commit,
      workflow_commit: t.workflow_commit,
      ticket_type: t.ticket_type,
      pending_transition: t.pending_transition,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }
  end

  def job(%Job{} = j) do
    %{
      id: j.id,
      state: j.state,
      attempt: j.attempt,
      status: j.status,
      outcome: j.outcome,
      declared_outcome: j.declared_outcome,
      # Which ceiling stopped a `budget_exhausted` job, null for every other. The UI is a client
      # of this (`docs/design/api-and-ui.md`), so a fact only the LiveViews carried would be a
      # fact no other client can read — and telling "ran out of money" from "ran out of turns"
      # is the whole of it (`docs/design/capacity.md` § Four exhaustions, three treatments).
      exhausted: j.exhausted,
      turns: j.turns,
      cost_usd: Decimal.to_string(j.cost_usd),
      harness_session_id: j.harness_session_id,
      started_at: j.started_at,
      finished_at: j.finished_at,
      inserted_at: j.inserted_at
    }
  end

  def job_with_spec(%Job{} = j), do: j |> job() |> Map.put(:spec, j.spec)

  def artifact(%Artifact{} = a, %Version{} = latest) do
    %{
      name: a.name,
      kind: a.kind,
      latest_version: latest.version,
      latest_version_id: latest.id,
      updated_at: latest.inserted_at
    }
  end

  def version(%Version{} = v, name) do
    %{
      id: v.id,
      artifact: name,
      version: v.version,
      author: v.author,
      content: v.content,
      blob_uri: v.blob_uri,
      content_hash: v.content_hash,
      meta: v.meta,
      inserted_at: v.inserted_at
    }
  end

  def question(%Question{} = q) do
    %{
      id: q.id,
      key: q.key,
      text: q.text,
      anchor: q.anchor,
      options: Enum.map(q.options, &option/1),
      blocking: q.blocking,
      assumption: q.assumption,
      line: q.line,
      artifact: q.artifact_version.artifact.name,
      artifact_version: q.artifact_version.version,
      asked_at: q.inserted_at
    }
  end

  @doc """
  One ticket proposal: what it says, who wrote it, and the version id every decision names.

  `version_id` rather than the artifact's id, because a decision attaches to an exact version —
  editing the title before accepting it is a new version with no decision, and an API that named
  the artifact would let a client accept text nobody had looked at.
  """
  def proposal(%{artifact: artifact, version: version} = found) do
    {title, body, type} =
      case ForgeCore.Proposal.parse(version.content || "") do
        {:ok, proposal} -> {proposal.title, proposal.body, proposal.ticket_type}
        {:error, errors} -> {nil, ForgeCore.Error.format(errors), nil}
      end

    %{
      version_id: version.id,
      file: artifact.name,
      title: title,
      body: body,
      suggested_type: type,
      readable: title != nil,
      job_id: artifact.job_id,
      ticket_number: found[:ticket_number],
      proposed_at: version.inserted_at
    }
  end

  def event(%Event{} = e) do
    %{
      seq: e.seq,
      type: e.type,
      actor: e.actor,
      payload: e.payload,
      job_id: e.job_id,
      at: e.inserted_at
    }
  end

  def queue_item(%{kind: kind, since: since} = item, project_name) do
    %{
      kind: kind,
      since: since,
      question: item.question && question(item.question),
      detail: detail(item)
    }
    |> Map.merge(queue_subject(item.ticket, project_name))
  end

  # A chat's questions are parsed from its reply and never stored, so they arrive as the core's
  # structs, which the JSON encoder refuses; they are served as a key, a text and options shaped
  # as a stored question's are — no id, line or anchor, which a message does not give them.
  defp detail(%{kind: :chat, detail: detail}),
    do: %{detail | questions: Enum.map(detail.questions, &chat_question/1)}

  defp detail(item), do: item.detail

  defp chat_question(q) do
    %{key: q.key, text: q.text, options: Enum.map(q.options, &option/1)}
  end

  defp option(option), do: Map.take(option, [:label, :detail, :recommended])

  # A conversation about a project has no ticket, no title of its own and no state. Naming the
  # project is what an API client has to go on, and inventing the other three would be a lie
  # that reads exactly like a ticket.
  defp queue_subject(nil, project_name),
    do: %{ticket: nil, title: nil, state: nil, project: project_name}

  defp queue_subject(ticket, project_name) do
    %{
      ticket: "#{project_name}##{ticket.number}",
      title: ticket.title,
      state: ticket.state,
      project: project_name
    }
  end

  @doc """
  The merge decision: the diff beside what the platform knows about it. The patch is served whole
  here — a client that asked for it can decide what to do with it — while the page bounds what it
  draws.
  """
  def review(%Ticket{} = ticket, %Project{} = project, %Version{} = changeset) do
    repo = Forge.Projects.repo_path(project)
    head = Forge.Artifacts.commit(changeset)

    %{
      ticket: ticket(ticket, project.name),
      changeset: %{version: changeset.version, commit: head, base: ticket.base_commit},
      merged: Forge.Merge.merged?(ticket),
      diff: diff(repo, ticket.base_commit, head),
      documents: review_artifacts(ticket, :document),
      presentations: review_artifacts(ticket, :presentation),
      answers: review_answers(ticket),
      cost_usd: Decimal.to_string(ticket.cost_usd)
    }
  end

  defp diff(repo, base, head) do
    with {:ok, stat} <- Forge.Git.diff_stat(repo, base, head),
         {:ok, patch} <- Forge.Git.diff(repo, base, head) do
      files =
        Enum.map(stat, fn {path, added, removed} ->
          %{path: path, added: added, removed: removed}
        end)

      %{files: files, patch: patch}
    else
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  # Documents and presentations are two keys of the payload and one comprehension: the kind is the
  # whole difference between them — a presentation is nothing's input and carries no approval — and
  # a client handed one among the documents would have no way to tell. Content as written; the
  # inline quoting is the page's rendering, not the payload's.
  defp review_artifacts(%Ticket{} = ticket, kind) do
    for artifact <- Forge.Artifacts.list(ticket.id),
        artifact.kind == kind,
        version = Forge.Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      %{name: artifact.name, version: version.version, content: version.content}
    end
  end

  defp review_answers(%Ticket{} = ticket) do
    for entry <- Forge.Artifacts.answered(ticket.id) do
      %{
        key: entry.question.key,
        text: entry.question.text,
        choice: entry.answer.choice,
        answer_text: entry.answer.text,
        artifact: entry.artifact,
        version: entry.version
      }
    end
  end
end
