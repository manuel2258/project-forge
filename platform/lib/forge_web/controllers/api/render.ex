defmodule ForgeWeb.Api.Render do
  @moduledoc "Plain maps for API responses. One function per shape; nothing clever."

  alias Forge.Artifacts.{Artifact, Question, Version}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket

  def project(%Project{} = p) do
    %{
      id: p.id,
      name: p.name,
      repo_path: p.repo_path,
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
      options: q.options,
      default: q.default,
      blocking: q.blocking,
      assumption: q.assumption,
      line: q.line,
      artifact: q.artifact_version.artifact.name,
      artifact_version: q.artifact_version.version,
      asked_at: q.inserted_at
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

  def queue_item(%{kind: kind, ticket: t, since: since} = item, project_name) do
    %{
      kind: kind,
      ticket: "#{project_name}##{t.number}",
      title: t.title,
      state: t.state,
      since: since,
      question: item.question && question(item.question),
      detail: item.detail
    }
  end
end
