defmodule ForgeCore.Prompt do
  @moduledoc """
  Composes the prompt a job's agent receives: the platform preamble, the project's state
  prompt, and the job manifest rendered from the spec. See `docs/design/job-prompt.md`.
  """

  alias ForgeCore.Job.Spec
  alias ForgeCore.Workflow

  @preamble_path Path.join(:code.priv_dir(:forge_core), "preamble.md")
  @external_resource @preamble_path
  @preamble File.read!(@preamble_path)
  @preamble_hash "sha256:" <> Base.encode16(:crypto.hash(:sha256, @preamble), case: :lower)

  @chat_preamble_path Path.join(:code.priv_dir(:forge_core), "chat-preamble.md")
  @external_resource @chat_preamble_path
  @chat_preamble File.read!(@chat_preamble_path)
  @chat_preamble_hash "sha256:" <>
                        Base.encode16(:crypto.hash(:sha256, @chat_preamble), case: :lower)

  @doc "The platform-owned preamble, identical for every job."
  @spec preamble() :: String.t()
  def preamble, do: @preamble

  @doc """
  The preamble a conversation gets, which is a different document and has to be.

  A conversation used to be handed the job preamble, and it contradicted everything the chat
  manifest said in the same prompt: "you are one job in a ticket lifecycle", write the declared
  outputs "and stop", `outcome` must be one of the allowed outcomes, a non-blocking question
  states the assumption it proceeded with. A conversation has no outcome, no declared outputs,
  no assumptions and — most damagingly — nothing to stop for. Reusing it was not economy; it was
  telling the agent to be a job.
  """
  @spec chat_preamble() :: String.t()
  def chat_preamble, do: @chat_preamble

  @doc "Hash of the preamble, recorded in every job spec."
  @spec preamble_hash() :: String.t()
  def preamble_hash, do: @preamble_hash

  @doc "Hash of the conversation preamble, recorded in a chat's spec."
  @spec chat_preamble_hash() :: String.t()
  def chat_preamble_hash, do: @chat_preamble_hash

  @doc "The full prompt for `spec`, given the absolute job directory."
  @spec compose(Spec.t(), String.t()) :: String.t()
  def compose(%Spec{kind: :chat} = spec, job_dir) do
    [
      @chat_preamble,
      "---\n\n" <> chat_manifest(spec, job_dir),
      "---\n\n" <> String.trim(spec.prompt || "")
    ]
    |> Enum.map_join("\n\n", &String.trim_trailing/1)
    |> Kernel.<>("\n")
  end

  def compose(%Spec{} = spec, job_dir) do
    [
      @preamble,
      "---\n\n# Project instructions for state `#{spec.state}`\n\n" <> String.trim(spec.prompt),
      "---\n\n" <> manifest(spec, job_dir)
    ]
    |> Enum.map_join("\n\n", &String.trim_trailing/1)
    |> Kernel.<>("\n")
  end

  @doc """
  What a workflow job is handed when it resumes its harness session: what changed while it was
  stopped, and the manifest as it stands now. See `docs/design/job-prompt.md` § The continuation
  prompt.

  The preamble and the state prompt are not repeated — the session already holds them, and they
  are the bulk of `compose/2`. The manifest is: it is short, it now lists `answers.md` among the
  inputs, and its budget is the one this run was assigned, which may have been lowered since.

  `head` is the commit the worktree is at, or nil when it could not be read.

  Only for a run that passes `--resume`. A cold start gets `compose/2`, and the caller chooses
  between them from the same value that puts the flag on the command line.

  `fork: true` is a new attempt of the state resuming its predecessor's session under a new id
  (`docs/design/claude-code-events.md` § Resume): it is told it is a new attempt that came back,
  and that nothing it wrote last time counts for this one.

  A conversation resumes too, after it was reopened, and is told only that: it has no manifest
  of a job's, and what the person said since is the rest of its prompt.
  """
  @spec continuation(Spec.t(), String.t(), String.t() | nil, keyword()) :: String.t()
  def continuation(spec, job_dir, head, opts \\ [])

  def continuation(%Spec{kind: :chat} = spec, _job_dir, head, _opts) do
    [
      """
      # This conversation was reopened

      It stopped, and this resumes your session in it: what was said and what you did are as you
      left them. Nothing of it needs reading again.
      """,
      chat_branch(spec, head),
      # What it holds now, which a session resumed from before a deletion still believes it has.
      blank_to_nil(secrets(spec)),
      if(blank?(spec.prompt), do: nil, else: "---\n\n" <> String.trim(spec.prompt))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n\n", &String.trim/1)
    |> Kernel.<>("\n")
  end

  def continuation(%Spec{} = spec, job_dir, head, opts) do
    [
      opening(spec, Keyword.get(opts, :fork, false)),
      answers(spec, job_dir),
      branch_state(spec, head),
      "---\n\n" <> manifest(spec, job_dir)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n\n", &String.trim/1)
    |> Kernel.<>("\n")
  end

  defp answers(%Spec{inputs: inputs}, job_dir) do
    case Enum.find(inputs, &(&1.name == Workflow.answers_artifact())) do
      nil ->
        nil

      input ->
        fence = fence(input.content)

        """
        ## Answers

        A person answered. `#{input.name}` version #{input.version} holds every answer on this
        ticket, oldest first; it is also at `#{Path.join([job_dir, "inputs", input.name])}`.

        #{fence}markdown
        #{String.trim(input.content)}
        #{fence}

        A question whose key has an answer does not stop the job again, so a block you leave in a
        document is not asked twice.
        """
    end
  end

  defp opening(_spec, false) do
    """
    # Continue this job

    This resumes your session on it. Your instructions are the ones you were given; below is
    what changed while you were stopped, and the manifest as it stands now. Where the manifest
    differs from what you remember, the manifest is right.
    """
  end

  # A fork: the session is the previous attempt's, and the job is a new one. The one thing it
  # must not carry over is the belief that its outputs are written — they were the last
  # attempt's, and this attempt's `out/` is empty.
  defp opening(%Spec{state: state, attempt: attempt}, true) do
    """
    # A new attempt of `#{state}`

    This is attempt #{attempt} of `#{state}`, and the session you are in is attempt
    #{attempt - 1}'s: what you remember is what you did then. The ticket went on from here and
    has come back — *How you got here* in the manifest below says from where and why — and your
    instructions are the ones you were given.

    **Nothing you wrote last time counts for this attempt.** Its outputs were kept as versions of
    their own; this attempt's output directory is empty, and every output the manifest declares
    is written again. Where the manifest differs from what you remember, the manifest is right.
    """
  end

  # Every turn of a conversation is committed as it ends, so the tree is what the last turn left;
  # a turn cut short when it stopped left only what it had committed.
  defp chat_branch(%Spec{branch: branch}, head) do
    at = if head, do: ", at `#{head}`", else: ""

    """
    ## Your branch

    `#{branch}`#{at}, checked out in the worktree you are running in, on what may be another
    machine. A turn that was cut short when it stopped left only what it had committed. If the
    conversation was closed in between, closing may have deleted the branch, merged or abandoned,
    and the reopen made it again from the branch it started from: what you remember committing
    is then in that branch if it was merged, and gone if not. `git log` says which.
    """
  end

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""

  defp blank_to_nil(text), do: if(blank?(text), do: nil, else: text)

  # Longer than any run of backticks in what it wraps, so a person's answer that quotes a fenced
  # block cannot close this one early and leave the rest of the prompt inside it.
  defp fence(content) do
    longest =
      ~r/`+/
      |> Regex.scan(content)
      |> Enum.map(fn [run] -> String.length(run) end)
      |> Enum.max(fn -> 0 end)

    String.duplicate("`", max(3, longest + 1))
  end

  # **What a resume says about the tree depends on whether the state kept one.** A state that
  # declares `changeset` had its tree committed and squashed when the run stopped, so the files
  # are the ones it left. A state that declares none had its tree discarded — never committed,
  # never pushed, never promoted as the ticket's template (`docs/design/git-hosting.md`
  # § Non-fast-forward on a ticket branch) — so the worktree is the branch as it stands, and
  # telling such an agent its files are as it left them is telling it something false about the
  # one thing it is about to act on.
  defp branch_state(%Spec{branch: branch} = spec, head) do
    at = if head, do: ", at `#{head}`", else: ""
    where = "`#{branch}`#{at}, checked out in the worktree you are running in."

    body =
      if Spec.changeset?(spec) do
        """
        #{where} What the earlier run had
        not committed was committed when it stopped, and a run's commits are squashed into one, so
        the history may not be the one you remember; the files are what you left.
        """
      else
        """
        #{where} `changeset` is not one of
        your outputs, so nothing of the earlier run's tree was kept: it was not committed and not
        pushed, and this worktree is the branch as it stands rather than the files you left. Your
        documents, and any command logs that came back with you, are what carried over.
        """
      end

    """
    ## Your branch

    #{body}
    """
  end

  @doc """
  What a conversation is told about where it is.

  Deliberately not the job manifest: there is no state to be in, no outcome to declare, no
  document that carries one and no budget of its own. Saying otherwise would invite the agent to
  end the conversation by writing an outcome, which is the disguise `docs/design/conversations.md`
  § Why it is not a workflow exists to avoid.
  """
  @spec chat_manifest(Spec.t(), String.t()) :: String.t()
  def chat_manifest(%Spec{} = spec, job_dir) do
    """
    # This is a conversation

    You are talking to a person. There is no state to leave and no outcome to declare: reply,
    and wait for what they say next. Work you commit on `#{spec.branch}` is kept and can be
    merged; nothing else about this conversation is a contract.

    #{about(spec)}
    - Job directory: `#{job_dir}`
    - Branch: `#{spec.branch}`

    ## Context (read-only)

    #{inputs(spec, job_dir)}
    #{history(spec, job_dir)}
    #{replay(spec, job_dir)}#{secrets(spec)}#{moving_the_ticket(spec, job_dir)}
    """
  end

  # What a ticket conversation may ask the engine for (`docs/design/conversations.md` § Taking a
  # transition). Only for a ticket chat: a project chat has no ticket, and a section about the
  # file would otherwise describe something it can never do.
  defp moving_the_ticket(%Spec{ticket: nil}, _job_dir), do: ""
  defp moving_the_ticket(%Spec{moving: nil}, _job_dir), do: ""

  defp moving_the_ticket(%Spec{moving: moving}, job_dir) do
    """

    ## Moving the ticket

    You can ask for a transition, or decide a pending one, by writing
    `#{Path.join(job_dir, "transition.json")}`; the preamble says how. Everything here is as of
    when this conversation started and the ticket may have moved since. **You will not be told
    what became of a request**: if it is refused, the reason is recorded for the person to read
    and nothing moves. Say what you asked for, so they know what to look for.
    #{offered(moving)}#{pending(moving)}#{live(moving)}
    """
  end

  # The pinning no longer parses, so there is nothing to offer and no honest list to print. Said
  # rather than shown as an empty state: the ticket cannot move at all until a person repins it,
  # which is a different problem from a state that simply declares no way out.
  defp offered(%{"workflow_broken" => true}),
    do:
      "\n- This ticket's pinned workflow no longer parses, so no transition can be offered or\n" <>
        "  taken. A person has to repin it before the ticket can move."

  defp offered(%{"transitions" => []}),
    do: "\n- No transition is declared out of the ticket's state, so there is none to ask for."

  defp offered(%{"transitions" => transitions}) do
    """

    Transitions out of the ticket's state:

    #{Enum.map_join(transitions, "\n", &edge/1)}
    """
  end

  # A target reached by two edges is listed and marked as not askable: the request carries a
  # target and no outcome, so the engine refuses it every time. Marked rather than dropped, so
  # the agent can tell the person the state exists and why it is out of reach.
  defp edge(%{"to" => to, "ambiguous" => true}),
    do:
      "- `#{to}` — **cannot be asked for**: two transitions go there and the request cannot say\n" <>
        "  which. Nor can the ticket page; only a direct API call can."

  defp edge(%{"to" => to} = transition) do
    case transition["approve"] || [] do
      [] -> "- `#{to}`"
      names -> "- `#{to}` — approves #{Enum.map_join(names, ", ", &"`#{&1}`")} on the way"
    end
  end

  defp pending(%{"pending" => nil}), do: ""

  defp pending(%{"pending" => decision}) do
    """

    A decision is already pending on this ticket: moving to `#{decision["to"]}`#{on_outcome(decision)}#{approving(decision["approve"] || [])}.
    Until it is decided no other transition can be taken — decide this one, or leave it to the
    person.
    """
  end

  defp on_outcome(%{"outcome" => outcome}) when is_binary(outcome), do: " on `#{outcome}`"
  defp on_outcome(_decision), do: ""

  defp approving([]), do: ""
  defp approving(names), do: ", approving " <> Enum.map_join(names, ", ", &"`#{&1}`")

  defp live(%{"job_live" => true}) do
    """

    A job of the ticket's state was running when this conversation started. While one is, no
    transition can be taken — the person cancels the ticket and restores it, which is what stops
    a job, and that is theirs to do and not yours.
    """
  end

  defp live(_moving), do: ""

  # A reopened conversation is a new process with none of the old one's context, and the
  # message at the end of this prompt is the next thing the person said — not the first. Told
  # so here, because an agent that took it for an opening would answer as though nothing had
  # been said, and one that took the file for its instructions would answer it all again. The
  # file is named rather than inlined for the reason `history/` is: it is read with the agent's
  # own tools, and a long conversation does not become one enormous first message.
  defp replay(%Spec{replay: nil}, _job_dir), do: ""

  defp replay(%Spec{}, job_dir) do
    path = Path.join(job_dir, Workflow.replay_file())

    """

    ## This conversation was reopened

    It went on before, in a process that has since stopped. What was said — the person's
    messages and your replies, oldest first — is in `#{path}`.
    **Read it before you reply.** It ends with your last reply, and the message at the end of
    this prompt is the next thing the person said — not the first.

    The checkout is your branch as it stands now, which may not hold everything those replies
    describe: `git log` says what is there.
    """
  end

  # Named rather than inlined. Each job that already ran on this ticket has a folder with its
  # metadata and its whole transcript, which together run to hundreds of kilobytes — read when
  # there is a reason to, not paid for on every turn.
  defp history(%Spec{ticket: nil}, _job_dir), do: ""

  defp history(%Spec{}, job_dir) do
    """

    ## What already ran on this ticket

    `#{Path.join(job_dir, "history")}/<state>/<attempt>/` — one folder per job that already ran,
    holding `job.md` — what it was, what it declared, what it wrote, what it cost — and
    `transcript.jsonl`, everything that job's agent did, one JSON object per line. Read them when
    you need to know why something was done; they are large.
    """
  end

  defp about(%Spec{ticket: nil}), do: "- About the repository as a whole."

  defp about(%Spec{ticket: ticket}),
    do: "- About ticket #{ticket.number}: #{ticket.title}"

  # The ticket's type, when the project has types: information, not a switch — a prompt shared by
  # two types that behaves differently by type is a branch the workflow file cannot see
  # (`docs/design/ticket-types.md` § What a job is told).
  defp ticket_type(%{ticket_type: type}) when is_binary(type), do: "- Type: `#{type}`\n"
  defp ticket_type(_ticket), do: ""

  @doc "The job manifest section: what this job is, its inputs, outputs, outcomes and budget."
  @spec manifest(Spec.t(), String.t()) :: String.t()
  def manifest(%Spec{} = spec, job_dir) do
    """
    # Job manifest

    - Ticket #{spec.ticket.number}: #{spec.ticket.title}
    #{ticket_type(spec.ticket)}- State: `#{spec.state}` (attempt #{spec.attempt})
    - Job directory: `#{job_dir}`
    - Branch: `#{spec.branch}` (workflow pinned at commit `#{spec.commit}`)

    ## How you got here

    #{arrival(spec.entered)}#{entered_commands(spec, job_dir)}#{integration(spec)}

    ## Inputs (read-only)

    #{inputs(spec, job_dir)}#{absent(spec)}

    ## Outputs to write

    #{outputs(spec, job_dir)}

    ## Allowed outcomes

    #{outcomes(spec)}
    #{may_invoke(spec, job_dir)}#{command_results(spec, job_dir)}#{secrets(spec)}

    ## Budget

    - Turns: #{spec.budget.turns}
    - Cost: #{spec.budget.cost} USD#{lowered(spec.budget)}#{allowance(spec.budget)}
    """
  end

  # Said, not left to an event log the agent cannot read: a job stopping at a tenth of its state's
  # budget, or saving a round it had plenty for, needs the figure that decided it.
  defp lowered(%{declared: declared, lowered_by: by}) do
    left = if by == "day", do: "what the day has left", else: "what the ticket has left"
    " — lowered from the state's #{declared} USD to #{left}"
  end

  defp lowered(_budget), do: ""

  defp allowance(%{ticket_left: left, ticket_limit: limit}),
    do:
      "\n- The ticket: #{format_usd(left)} of #{format_usd(limit)} USD left for every job still to run on it"

  defp allowance(_budget), do: ""

  defp format_usd(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_usd(value), do: to_string(value)

  defp inputs(%Spec{inputs: []}, _job_dir), do: "- none"

  defp inputs(%Spec{inputs: inputs} = spec, job_dir) do
    Enum.map_join(inputs, "\n", fn input ->
      "- `#{input.name}` version #{input.version} -> `#{Path.join([job_dir, "inputs", input.name])}`" <>
        since(input, spec)
    end)
  end

  # A second visit to a state that reads the changeset — a review after rework — opens with what
  # changed since the first, and re-derived it from the whole diff every time.
  defp since(%{name: "changeset", version: version}, %Spec{previous_changeset: sha, attempt: n})
       when is_binary(sha) and sha != version do
    "\n  attempt #{n - 1} of this state read it at `#{String.slice(sha, 0, 12)}`; " <>
      "`git diff #{sha}` is what changed on the branch since"
  end

  defp since(%{name: "changeset"}, %Spec{previous_changeset: sha, attempt: n})
       when is_binary(sha),
       do: "\n  attempt #{n - 1} of this state read the same commit; nothing changed since"

  defp since(_input, _spec), do: ""

  # `docs/design/job-prompt.md` § How the job arrived. A second visit to a state is there because
  # something sent it back, and the job has to be told what and why rather than infer it from
  # which inputs changed.
  defp arrival(nil), do: "This is the ticket's first state."

  defp arrival(%{"from" => from, "by" => by} = entered) do
    who = if by == "person", do: "a person", else: "the engine"
    on = if entered["outcome"], do: " on `#{entered["outcome"]}`", else: ""

    "The ticket came from `#{from}`#{on}; #{who} took the transition." <>
      comment(entered["comment"])
  end

  defp comment(text) when is_binary(text) and text != "" do
    fence = fence(text)
    "\n\nThey wrote:\n\n#{fence}text\n#{String.trim(text)}\n#{fence}"
  end

  defp comment(_none), do: ""

  # The commands of the state that sent the ticket here, when that state was a command state: the
  # reason it sent it is in their logs, and the job that has to act on a failed build cannot act on
  # the outcome's name alone.
  defp entered_commands(%Spec{entered_commands: []}, _job_dir), do: ""

  defp entered_commands(%Spec{entered_commands: results, entered: %{"from" => from}}, job_dir) do
    lines = Enum.map_join(results, "\n", &command_result(&1, job_dir))

    "\n\nWhat `#{from}`'s commands said, in the order it ran them. Read the log of any that " <>
      "failed before you change anything: it is why you are here.\n\n" <> lines
  end

  # `docs/design/job-prompt.md` § Integrating the default branch. A job of a merging state's
  # `on_conflict` target is there to merge the default branch into the ticket's, and is told what
  # conflicted, what landed meanwhile, and to merge rather than rebase.
  defp integration(%Spec{integration: %{"default_branch" => branch} = integration}) do
    remote = "origin/" <> branch

    Enum.join(
      [
        "\n\n## Integrating `#{branch}`",
        "This ticket's changeset no longer merges into `#{branch}`, which is why you are here. " <>
          integration_head(integration["head"], branch, remote),
        integration_conflict(integration["paths"] || [], integration["changeset"], remote),
        integration_merges(integration, branch),
        "Merge `#{remote}` into the branch — `git merge #{remote}` — resolve every conflict, and " <>
          "commit the merge. **Do not rebase, and do not reset the branch.** The commit this " <>
          "ticket's merge was last tried for has to stay an ancestor of what you leave, and only " <>
          "a merge keeps it one. Your run is squashed into one commit when it ends, as always, " <>
          "and that commit keeps `#{remote}` as its second parent, so the merge survives it."
      ]
      |> Enum.reject(&(&1 == "")),
      "\n\n"
    )
  end

  defp integration(%Spec{}), do: ""

  defp integration_head(head, branch, remote) when is_binary(head),
    do:
      "`#{branch}` was at `#{short(head)}` when this run was assigned. The checkout has it as " <>
        "`#{remote}`, which may be a little newer: that is the one to merge."

  defp integration_head(_none, branch, remote),
    do: "The checkout has `#{branch}` as `#{remote}`: that is the one to merge."

  defp integration_conflict([], _changeset, remote),
    do:
      "No conflict is recorded for this ticket: a person sent it here. Merge `#{remote}` all " <>
        "the same, and say what you found."

  defp integration_conflict(paths, changeset, _remote) do
    tried = if changeset, do: " when its changeset `#{short(changeset)}` was tried", else: ""

    "It conflicted in these paths#{tried}:\n\n" <>
      Enum.map_join(paths, "\n", &"- `#{&1}`")
  end

  defp integration_merges(%{"merges" => [_ | _] = merges} = integration, branch) do
    since =
      if integration["base"], do: " since this ticket's base `#{short(integration["base"])}`"

    more = integration["more"] || 0

    "What has landed on `#{branch}`#{since}, newest first — which ticket wrote the other side " <>
      "of a conflict is what says how to resolve it:\n\n" <>
      Enum.map_join(merges, "\n", &"- `#{short(&1["sha"])}` #{&1["subject"]}") <>
      if(more > 0, do: "\n- and #{more} more", else: "")
  end

  defp integration_merges(_integration, _branch), do: ""

  defp short(sha), do: String.slice(sha, 0, 12)

  # Optional inputs not written yet: named, so a missing file is not mistaken for a failure
  # (`docs/design/workflow-grammar-v1.md` § Inputs).
  defp absent(%Spec{absent_inputs: []}), do: ""

  defp absent(%Spec{absent_inputs: names}) do
    "\n" <>
      Enum.map_join(names, "\n", fn name ->
        "- `#{name}`: not written on this ticket yet; it may be on a later visit to this state"
      end)
  end

  defp outputs(%Spec{produces: produces} = spec, job_dir) do
    outcome_document = Spec.outcome_document(spec)

    Enum.map_join(produces, "\n", fn name ->
      cond do
        Workflow.group?(name) ->
          dir = Path.join([job_dir, "out", Workflow.group_name(name)])

          "- `#{name}` -> any number of files in `#{dir}/`, each kept as " <>
            "`#{Workflow.group_name(name)}/<file>`; names are letters, digits, `.`, `_` and `-`"

        not Workflow.document?(name) ->
          "- `#{name}`: the diff of your commits on `#{spec.branch}`; no file to write"

        name == outcome_document ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}` (carries the outcome)"

        true ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}`"
      end
    end)
  end

  # Named, never valued: the values are in the environment and nowhere in this prompt. What it asks
  # is a request, and says so — masking is the worker's, and catches only the exact value
  # (`docs/design/secrets.md` § Masking). A conversation reopened after one of its secrets was
  # deleted is told which, here and in its continuation, rather than finding the variable missing.
  defp secrets(%Spec{secrets: [], secrets_gone: []}), do: ""

  defp secrets(%Spec{secrets: names, secrets_gone: gone}) do
    """

    ## Secrets in your environment
    #{held(names)}#{gone(gone)}
    """
  end

  defp held([]), do: ""

  defp held(names) do
    """

    #{vars(names)} — set for your work by the project. Use them where
    your work needs them. Do not print them, commit them, or write them into a document, a
    proposal or a command's arguments: anything you print may be read by every member of the
    project. The exact value is masked where it leaves the machine, which is a safety net and
    not a reason to print it.
    """
  end

  defp gone([]), do: ""

  defp gone(names) do
    """

    #{vars(names)} — deleted by the project since this conversation was opened, and no longer
    set. Anything earlier in it that used them will not work now.
    """
  end

  defp vars(names), do: Enum.map_join(names, ", ", &"`$#{&1}`")

  # `docs/design/job-prompt.md` § Commands: what this job's agent may run, how many remain, and
  # the one way to ask. Absent for a state that may not invoke, so no other job is told how to use
  # a file the preamble names only as one to leave alone.

  defp may_invoke(%Spec{may_invoke: grants}, _job_dir) when map_size(grants) == 0, do: ""

  defp may_invoke(%Spec{may_invoke: grants} = spec, job_dir) do
    lines =
      grants
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, grant} ->
        remaining = grant["remaining"] || grant["max"]
        at_once = if grant["concurrent"], do: ", at most #{grant["concurrent"]} at once", else: ""
        "- `#{name}`: #{remaining} of #{grant["max"]} invocations left#{at_once}"
      end)

    """

    ## Commands you may run

    #{lines}

    To run them, write `#{Path.join(job_dir, "invoke.json")}` — a JSON array such as
    `[{"command": "build", "args": ["--release"]}, {"command": "test"}]` — and end your run
    without writing your outputs. #{at_what(spec)} Ask
    for everything you need at once: every round is a resume. Run quick checks yourself; commands
    are for what is expensive, shared or decides whether the work is done.
    """
  end

  # The commit a command runs at is the push the run just made — but only a state that declares
  # `changeset` makes one (`docs/design/commands.md` § The ensured commit). For any other state
  # the commands run at the branch as the run found it, which is the one thing an agent deciding
  # whether a command will see its edits needs to know.
  defp at_what(%Spec{} = spec) do
    if Spec.changeset?(spec) do
      "Your work is committed and pushed, the commands run against " <>
        "that commit on another machine, and you are resumed with their exit statuses and logs."
    else
      "`changeset` is not one of your outputs, so nothing of your tree is committed or pushed: " <>
        "the commands run on another machine against `#{spec.branch}` as this run found it, " <>
        "without your edits, and you are resumed with their exit statuses and logs."
    end
  end

  defp command_results(%Spec{command_results: []}, _job_dir), do: ""

  defp command_results(%Spec{command_results: results}, job_dir) do
    lines = Enum.map_join(results, "\n", &command_result(&1, job_dir))

    """

    ## Commands you ran

    What you asked for when you last stopped, as it came back:

    #{lines}
    """
  end

  defp command_result(%{"refused" => reason} = result, _job_dir) when is_binary(reason),
    do: "- #{invocation(result)}: refused — #{reason}"

  defp command_result(result, job_dir) do
    at = if result["at"], do: " at `#{String.slice(result["at"], 0, 12)}`", else: ""

    log =
      if result["log"], do: "; log `#{Path.join([job_dir, "commands", result["log"]])}`", else: ""

    "- #{invocation(result)}#{at}: #{ended(result)}#{took(result["duration_ms"])}#{log}"
  end

  # The argument vector as JSON, because it reached `exec` as a vector: joined with spaces, two
  # arguments and one containing a space would read the same.
  defp invocation(%{"command" => command} = result) do
    case result["args"] do
      [_ | _] = args -> "`#{command}` `#{ForgeCore.Workflow.Command.argv(args)}`"
      _none -> "`#{command}`"
    end
  end

  defp ended(%{"exit_status" => status}) when is_integer(status), do: "exit #{status}"
  defp ended(%{"outcome" => "cancelled"}), do: "cancelled before it finished"

  defp ended(_result),
    do: "no exit status — it outlived its timeout or could not be run"

  defp took(ms) when is_integer(ms), do: " in #{max(div(ms, 1000), 1)}s"
  defp took(_none), do: ""

  defp outcomes(%Spec{outcomes: outcomes}) do
    listed = Enum.map_join(outcomes, ", ", &"`#{&1}`")
    "#{listed}, or `did_not_converge` if the work could not be completed."
  end
end
