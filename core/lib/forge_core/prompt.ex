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
  """
  @spec continuation(Spec.t(), String.t(), String.t() | nil) :: String.t()
  def continuation(%Spec{} = spec, job_dir, head) do
    [
      """
      # Continue this job

      This resumes your session on it. Your instructions are the ones you were given; below is
      what changed while you were stopped, and the manifest as it stands now. Where the manifest
      differs from what you remember, the manifest is right.
      """,
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

  defp branch_state(%Spec{branch: branch}, head) do
    at = if head, do: ", at `#{head}`", else: ""

    """
    ## Your branch

    `#{branch}`#{at}, checked out in the worktree you are running in. What the earlier run had
    not committed was committed when it stopped, and a run's commits are squashed into one, so
    the history may not be the one you remember; the files are what you left.
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
    #{replay(spec, job_dir)}
    """
  end

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

  @doc "The job manifest section: what this job is, its inputs, outputs, outcomes and budget."
  @spec manifest(Spec.t(), String.t()) :: String.t()
  def manifest(%Spec{} = spec, job_dir) do
    """
    # Job manifest

    - Ticket #{spec.ticket.number}: #{spec.ticket.title}
    - State: `#{spec.state}` (attempt #{spec.attempt})
    - Job directory: `#{job_dir}`
    - Branch: `#{spec.branch}` (workflow pinned at commit `#{spec.commit}`)

    ## Inputs (read-only)

    #{inputs(spec, job_dir)}

    ## Outputs to write

    #{outputs(spec, job_dir)}

    ## Allowed outcomes

    #{outcomes(spec)}

    ## Budget

    - Turns: #{spec.budget.turns}
    - Cost: #{spec.budget.cost} USD
    """
  end

  defp inputs(%Spec{inputs: []}, _job_dir), do: "- none"

  defp inputs(%Spec{inputs: inputs}, job_dir) do
    Enum.map_join(inputs, "\n", fn input ->
      "- `#{input.name}` version #{input.version} -> `#{Path.join([job_dir, "inputs", input.name])}`"
    end)
  end

  defp outputs(%Spec{produces: produces} = spec, job_dir) do
    outcome_document = Spec.outcome_document(spec)

    Enum.map_join(produces, "\n", fn name ->
      cond do
        not Workflow.document?(name) ->
          "- `#{name}`: the diff of your commits on `#{spec.branch}`; no file to write"

        name == outcome_document ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}` (carries the outcome)"

        true ->
          "- `#{name}` -> `#{Path.join([job_dir, "out", name])}`"
      end
    end)
  end

  defp outcomes(%Spec{outcomes: outcomes}) do
    listed = Enum.map_join(outcomes, ", ", &"`#{&1}`")
    "#{listed}, or `did_not_converge` if the work could not be completed."
  end
end
