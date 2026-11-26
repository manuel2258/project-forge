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

  @doc """
  A ticket as the API shows it. `opts` carries what a list has already read for all its tickets,
  so that a list does not ask once per row: `:started` (a boolean) and `:milestones` (a map of
  milestone id to name).
  """
  def ticket(%Ticket{} = t, project_name, opts \\ []) do
    base = ticket_fields(t, project_name, opts)
    if Keyword.get(opts, :offers, false), do: Map.merge(base, offers(t)), else: base
  end

  # What a person may do about a job that ran out, and the cap it is judged against
  # (`docs/design/workflow-grammar-v1.md` § Extending a job). Not in a list, which would parse
  # every ticket's workflow to say it: `show` and the acts that answer with the ticket ask for it.
  defp offers(%Ticket{} = t) do
    case Forge.Tickets.parsed_workflow(t) do
      {:ok, workflow} ->
        facts = Forge.Jobs.Extensions.cap_facts(t, workflow)

        %{
          cap: facts.cap,
          cap_raise: facts.cap_raise,
          workflow_cap: facts.workflow_cap,
          left: facts.left,
          restart_need: facts.restart_need,
          retry: Forge.Engine.retryable?(t),
          extend: Forge.Jobs.Extensions.offer(t),
          warm_build: warm_build(t)
        }

      {:error, _errors} ->
        %{cap: nil, cap_raise: t.cap_raise, retry: false, extend: nil, warm_build: nil}
    end
  end

  # The ticket's warm build, as the ticket page draws it (`Forge.WarmBuilds`): null when no command
  # of its workflow keeps a build, otherwise `%{copy: null | %{...}}` — the copy the next command is
  # sent to, which is the latest one only. Nothing of the copy itself leaves its machine.
  defp warm_build(%Ticket{} = t) do
    if Forge.WarmBuilds.declared?(t) do
      %{copy: t |> Forge.WarmBuilds.current() |> warm_copy()}
    end
  end

  defp warm_copy(nil), do: nil

  defp warm_copy(%{job: job, worker: worker, size: size, kept_at: kept_at}) do
    command = job.spec["command"] || %{}

    %{
      size: size,
      machine: worker.id,
      command: command["name"],
      args: command["args"] || [],
      commit: command["at"],
      job_id: job.id,
      kept_at: kept_at
    }
  end

  defp ticket_fields(%Ticket{} = t, project_name, opts) do
    %{
      id: t.id,
      ref: "#{project_name}##{t.number}",
      project: project_name,
      number: t.number,
      title: t.title,
      body: t.body,
      state: t.state,
      status: t.status,
      usage: t.usage,
      branch: t.branch,
      base_commit: t.base_commit,
      workflow_commit: t.workflow_commit,
      ticket_type: t.ticket_type,
      pending_transition: t.pending_transition,
      on_hold: Ticket.held?(t),
      held_at: t.held_at,
      started: Keyword.get_lazy(opts, :started, fn -> Forge.Tickets.started?(t) end),
      stoppable: Forge.Engine.stoppable?(t),
      waiting_on_release: waiting_on_release(t),
      milestone: milestone(t, opts),
      position: t.position,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }
  end

  defp waiting_on_release(%Ticket{} = t) do
    case Forge.Engine.waiting_on_release_or_job(t) do
      {:transition, from, to, outcome} ->
        %{transition: %{from: from, to: to, outcome: outcome}}

      {:entry, state} ->
        %{entry: state}

      nil ->
        nil
    end
  end

  defp milestone(%Ticket{milestone_id: nil}, _opts), do: nil

  defp milestone(%Ticket{milestone_id: id}, opts) do
    name =
      case Keyword.fetch(opts, :milestones) do
        {:ok, names} -> Map.get(names, id)
        :error -> Forge.Milestones.name(id)
      end

    %{id: id, name: name}
  end

  @doc "A milestone with its progress and the numbers of its open tickets, in order."
  def milestone_entry(%{milestone: m, open: open, progress: progress}) do
    %{
      id: m.id,
      name: m.name,
      description: m.description,
      position: m.position,
      current: m.current,
      closed_at: m.closed_at,
      progress: progress,
      tickets: Enum.map(open, & &1.number)
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
      # How long a run of the job may take as it was made — the extension's, where a person gave
      # one, is on each of `extensions` — in milliseconds (`ForgeCore.Duration` writes it for a
      # person). A conversation's is the node's, a command's its own.
      timeout_ms: Forge.Jobs.own_timeout_ms(j),
      turns: j.turns,
      usage: j.usage,
      harness_session_id: j.harness_session_id,
      started_at: j.started_at,
      finished_at: j.finished_at,
      inserted_at: j.inserted_at,
      warm: warm(j)
    }
  end

  @doc """
  A command job: a job's fields, and the command it ran, its arguments and its exit status. `warm`
  is what the worker reported of the ticket's warm build (`docs/design/worker-tier.md` § The
  command copy).
  """
  def command(%Job{} = j) do
    command = (j.spec || %{})["command"] || %{}

    j
    |> job()
    |> Map.merge(%{
      kind: "command",
      command: command["name"],
      args: command["args"] || [],
      exit_status: j.exit_status
    })
  end

  # A command's warm build as it reported it (`docs/design/worker-tier.md` § The command copy), read
  # from the row with no lookups; null for a job that is not a command and for a command whose
  # worker reported nothing.
  defp warm(%Job{warm_source: nil, warm_kept: nil}), do: nil

  defp warm(%Job{} = j) do
    %{
      source: j.warm_source,
      from_job_id: j.warm_from_id,
      kept: j.warm_kept,
      unkept: j.warm_unkept,
      size: j.warm_size
    }
  end

  def job_with_spec(%Job{kind: :command} = j), do: j |> command() |> with_spec(j)
  def job_with_spec(%Job{} = j), do: j |> job() |> with_spec(j)

  defp with_spec(map, %Job{} = j) do
    Map.merge(map, %{
      spec: j.spec,
      restart: restart(j),
      extensions: Enum.map(Forge.Jobs.Extensions.all(j.id), &extension/1),
      runs: Enum.map(Forge.Jobs.Runs.for_job(j.id), &run/1)
    })
  end

  # Each extension a person gave the job, oldest first, with who and the cap raise that came with
  # it. The job's `spec` above is the one it was made with: these are what its later runs read.
  defp extension(%Forge.Jobs.Extension{} = e) do
    raise = Forge.Repo.get_by(Forge.Tickets.CapRaise, extension_id: e.id)

    %{
      id: e.id,
      author: Forge.Jobs.Extensions.author(e),
      tokens: e.tokens,
      turns: e.turns,
      timeout_ms: e.timeout_ms,
      note: e.note,
      exhausted: e.exhausted,
      stopped_at: e.stopped_at,
      usage_before: e.usage_before,
      raise: raise && %{from: raise.from_tokens, to: raise.to_tokens},
      inserted_at: e.inserted_at
    }
  end

  # The person's *Run again* that made this job, with who and the note it arrived with, or nil.
  defp restart(%Job{restart_id: nil}), do: nil

  defp restart(%Job{restart_id: id}) do
    restart = Forge.Repo.get!(Forge.Tickets.Restart, id)

    %{
      id: id,
      author: Forge.Jobs.Extensions.author(restart),
      note: restart.note,
      inserted_at: restart.inserted_at
    }
  end

  defp run(%Forge.Jobs.Run{} = r) do
    %{
      started_at: r.started_at,
      finished_at: r.finished_at,
      usage: r.usage,
      extension_id: r.extension_id,
      resumed: r.resumed
    }
  end

  def artifact(%Artifact{} = a, %Version{} = latest) do
    %{
      name: a.name,
      kind: a.kind,
      latest_version: latest.version,
      latest_version_id: latest.id,
      updated_at: latest.inserted_at
    }
  end

  @doc """
  One artifact with all its versions: enough for a client to choose what to fetch. `form` says how
  — `text` and `file` are bytes at `.../:version/raw`, `commit` is the changeset, whose diff is the
  review endpoint's.
  """
  def artifact_listing(%Artifact{} = a, versions) do
    %{
      name: a.name,
      kind: a.kind,
      versions:
        Enum.map(versions, fn v ->
          %{
            number: v.version,
            id: v.id,
            author: v.author,
            inserted_at: v.inserted_at,
            content_hash: v.content_hash,
            form: form(v)
          }
        end)
    }
  end

  defp form(%Version{} = v) do
    cond do
      Forge.Artifacts.commit(v) -> :commit
      is_binary(v.blob_uri) -> :file
      true -> :text
    end
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

  @doc "A file withdrawn: its record, which stays, and who withdrew it and why."
  def withdrawn(%Forge.Attachments.Attachment{} = a) do
    %{
      id: a.id,
      name: a.name,
      original_name: a.original_name,
      size: a.size,
      withdrawn_at: a.withdrawn_at,
      withdrawn_by: a.withdrawn_by,
      reason: a.withdraw_reason
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

  @doc """
  The schedules one type's file declares, as `Forge.Schedules.declared/3` read them: one object
  each, with what the file says (`cron`, `title`, `body`) and what a person did about it. A file
  that does not parse lists the schedules that are on, by name, with the file's problem.
  """
  def schedules(%{type: type, schedules: schedules, error: error}) do
    Enum.map(schedules, fn s ->
      s.row
      |> then(&schedule(type, s, &1))
      |> Map.put(:file_error, error && ForgeCore.Error.to_text(error))
    end)
  end

  @doc "One schedule: `declared` is what the file says (nil when it cannot be read), `row` what is kept."
  def schedule(type, declared, row) do
    declared = declared || %{name: row.name, cron: row.cron, title: nil, body: nil, next_at: nil}

    Map.merge(
      %{
        type: type,
        name: declared.name,
        cron: declared.cron,
        title: declared.title,
        body: declared.body,
        next_at: declared.next_at
      },
      kept_schedule(row)
    )
  end

  defp kept_schedule(nil) do
    %{
      on: false,
      enabled_by: nil,
      enabled_at: nil,
      last_ticket: nil,
      problem: nil,
      problem_kind: nil,
      problem_at: nil,
      alert_open: false
    }
  end

  defp kept_schedule(%Forge.Schedules.Schedule{} = row) do
    on = Forge.Schedules.Schedule.on?(row)

    %{
      on: on,
      enabled_by: if(on, do: row.enabled_by && row.enabled_by.email),
      enabled_at: if(on, do: row.enabled_at),
      last_ticket: row.last_ticket && row.last_ticket.number,
      problem: row.problem,
      problem_kind: row.problem_kind,
      problem_at: row.problem_at,
      alert_open: row.alerted_at != nil
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
      # What the merge commit will say, beside the diff it is about: the page draws it above the
      # approve control, so a client deciding the same thing has it too. Null where nothing has
      # written one: a merge with nothing to say, or an old pin's, which says what 0.15.0 wrote.
      commit_message: review_commit_message(ticket),
      merged: Forge.Merge.merged?(ticket),
      diff: diff(repo, ticket.base_commit, head, changeset.blob_uri),
      documents: review_artifacts(ticket, :document),
      presentations: review_artifacts(ticket, :presentation),
      answers: review_answers(ticket),
      usage: ticket.usage
    }
  end

  # `text` is the body the merge commits (`ForgeCore.Document.body/1`), not the version's raw
  # content: a client that showed the raw text would show front matter the commit will not carry.
  defp review_commit_message(%Ticket{} = ticket) do
    case Forge.Merge.commit_message(ticket) do
      nil -> nil
      version -> %{version: version.version, text: ForgeCore.Document.body(version.content)}
    end
  end

  # Nil where the stored uri is not a commit, as the ticket's Changes view and `Merge.changeset/1`
  # both say in their own words: interpolated, it makes `base..`, which git reads as
  # `base..HEAD` and answers with the default branch's diff as this ticket's change.
  defp diff(_repo, _base, nil, uri), do: %{error: inspect({:not_a_commit, uri})}

  # The same bound the pages draw a change under (`ForgeWeb.Diff`), for the same reason and one
  # layer earlier: `Jason` raises on a binary that is not valid UTF-8, so a patch touching a
  # latin-1 file turned this endpoint into a 500. The map of the change is still every file —
  # the paths are safe because `Forge.Git` makes them so — and `patch` is null with `text:
  # false` beside it, which is a client's cue to read it with git rather than a silent truncation.
  defp diff(repo, base, head, _uri) do
    with {:ok, stat} <- Forge.Git.diff_stat(repo, base, head),
         {:ok, patch} <- Forge.Git.diff(repo, base, head) do
      files =
        Enum.map(stat, fn {path, added, removed} ->
          %{path: path, added: added, removed: removed}
        end)

      text? = ForgeCore.Document.text?(patch)
      %{files: files, patch: if(text?, do: patch), text: text?}
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
        version: entry.version,
        author: answer_author(entry)
      }
    end
  end

  # An answer is a person's or a token's, and says which. The token's name is as the token has it
  # now, which for a hand-minted token is as it was issued: the row is never deleted.
  defp answer_author(%{answer: %{token_id: token_id}, token_name: name}) when is_binary(token_id),
    do: %{kind: "api", id: token_id, name: name}

  defp answer_author(%{answer: %{user_id: user_id}}), do: %{kind: "user", id: user_id, name: nil}
end
