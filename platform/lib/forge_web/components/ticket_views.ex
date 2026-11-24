defmodule ForgeWeb.TicketViews do
  @moduledoc """
  What `ForgeWeb.TicketLive` draws inside the frame (`docs/design/ui.md` § The ticket): Steps,
  Activity, the details dropped from the title, the release band, the dock above the strip and,
  on a wide screen, the document a decision waits on beside the view.

  **Where the Decide tab's contents went** (`ui.md` § Steps): a document's questions to the
  question pane in the dock, on every view; the transition card and *Run again* to **Ways
  forward** under the current step — a choice row each and a dock button naming the one picked;
  a human state's editors and the merge queue to the current step; assumptions under Steps,
  unaccented; the not-buildable page to Steps' whole content. The approval is the decision row's.

  Every control here sends an event `TicketLive` handles; nothing in this module handles one.
  """

  use ForgeWeb, :html

  import ForgeWeb.Actions, only: [keep_open: 0]
  import ForgeWeb.Indicators

  import ForgeWeb.Operator.Components,
    only: [merge_queue_card: 1, document_editor: 1, merge_queue_place: 1]

  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1]

  alias Forge.{Artifacts, Conversations, Git, Jobs, Projects}
  alias ForgeCore.Workflow
  alias ForgeWeb.Components.{MoreRoom, StepAccept}
  alias ForgeWeb.{Diff, FileType, Format, WorkScreen}
  alias ForgeWeb.Operator.{Actions, Decision, QuestionForm}

  # The events whose type alone does not say what happened: which outcome a batch decided, why the
  # ticket stuck, where it went, why a conversation's request to move it moved nothing, the note a
  # decision was made with — a rejection always has one (`ui.md` § The decision row). Activity's
  # *On the ticket* lists these with what each says.
  @said ~w(commands.decided ticket.stuck transition.taken ticket.merge_conflicted
           chat.transition_refused merge_queue.entered merge_queue.returned merge_queue.taken_out
           merge_queue.left ticket.merged ticket.renamed approval.approved approval.rejected
           ticket.cancelled ticket.restored ticket.repinned ticket.held ticket.released
           ticket.stopped ticket.refreshed transition.held ticket.retitled
           ticket.milestone_set ticket.moved ticket.branch_updated ticket.base_moved
           ticket.retried job.extended ticket.cap_raised ticket.admitted attachment.added
           attachment.withdrawn page.published page.data_changed page.outside_access)

  @doc """
  Who an event of the ticket's Activity was made by, in the words the product uses: a person by
  their address in `addresses` and an API token by its name (`Format.author/2`), and a **jump** as
  its row on Steps says it — *you*, *a member* or *the engine* (the merge line's own move)
  (`docs/design/ui.md` § Activity). Nil for the engine, and for a person not in `addresses`.
  """
  @spec made_by(map(), String.t(), %{String.t() => String.t()}) :: String.t() | nil
  def made_by(
        %{actor: actor, type: "transition.taken", payload: %{"jump" => true}},
        me,
        _addresses
      ),
      do: jumper(actor, me)

  def made_by(%{actor: actor}, _me, addresses), do: Format.author(actor, addresses)

  @doc """
  Who made a jump, as the product says it (`docs/design/ui.md` § Activity): the viewer as *you*, the
  API token by its name, another member as *a member* (their address is not shown to the other
  members), and the merge line's own move as *the engine*. Steps and Activity both say it this way.
  """
  @spec jumper(map(), String.t()) :: String.t() | nil
  def jumper(%{"kind" => "user", "id" => me}, me), do: "you"
  def jumper(%{"kind" => "user"}, _me), do: "a member"
  def jumper(%{"kind" => "api"} = actor, _me), do: Format.author(actor)
  def jumper(_system, _me), do: "the engine"

  @doc "The ticket's event types Activity says in words, beside what its jobs did."
  @spec said_types() :: [String.t()]
  def said_types, do: @said

  @doc """
  Who wrote a version, in the words a Docs row uses: the job by its state and attempt, a person,
  or an API token by its name. `jobs` are the ticket's, by id.
  """
  @spec written_by(map() | nil, %{String.t() => map()}) :: String.t() | nil
  def written_by(%{"kind" => "job", "id" => id} = author, jobs) do
    case jobs[id] do
      %{kind: :chat, state: state} -> "conversation · #{state}"
      %{kind: :command, state: state} -> "command · #{state}"
      %{state: state, attempt: attempt} -> "agent · #{state} ##{attempt}"
      nil -> Format.author(author)
    end
  end

  def written_by(%{"kind" => "user"}, _jobs), do: "a person"
  def written_by(author, _jobs), do: Format.author(author)

  # -- the strip -----------------------------------------------------------------------------

  @doc """
  The ticket's views as its strip and title-row tabs draw them (`docs/design/ui.md` § The bottom
  strip): Talk while there is a conversation to talk in, then Steps, Changes, Docs and Activity
  with their counts. **One list for the ticket's page and its job's** (§ The job page: "the strip
  the ticket's"): the ticket's own page patches to a view (`:patch`), a job's navigates back to
  it (`:navigate`).
  """
  @spec strip(map(), map(), map(), map() | nil, :patch | :navigate) :: [map()]
  def strip(project, ticket, counts, talk, link) do
    path = ~p"/tickets/#{project.name}/#{ticket.number}"

    talk_tab =
      if talk,
        do: [%{key: "talk", label: "Talk", count: nil, navigate: ~p"/chats/#{talk.id}"}],
        else: []

    views =
      for {key, label, count} <- [
            {"steps", "Steps", nil},
            {"changes", "Changes", counts.changes},
            {"docs", "Docs", counts.docs},
            {"activity", "Activity", counts.activity}
          ],
          do: Map.put(%{key: key, label: label, count: count}, link, "#{path}?tab=#{key}")

    talk_tab ++ views
  end

  @doc """
  The ticket's strip for a page of its that is not the ticket's own — a job's, a step's
  conversation — with every count read as the ticket's page reads it: Changes what the branch holds
  against its base, Docs as Docs counts them, Activity the stream of the job running now
  (`current`, the ticket's newest job) as the Activity tab counts it, and Talk while the ticket has
  a conversation to talk in. Each view navigates back to the ticket's page. `held` is the figure the
  page already holds for one job, `{job_id, count}` (`ForgeWeb.JobStream`), so that job's stream is
  not counted again; any other is counted by the database (`Forge.Events.Stream.count/1`), never
  by reading the stream.
  """
  @spec strip_of(map(), map(), map() | nil, {String.t(), non_neg_integer()} | nil) :: [map()]
  def strip_of(project, ticket, current, held \\ nil) do
    activity =
      case {current, held} do
        {nil, _held} -> 0
        {%{id: id}, {id, count}} -> count
        {current, _held} -> Forge.Events.Stream.count(current.id)
      end

    # A page is one doc and its files are none (`ForgeWeb.PageViews`).
    pages = ForgeWeb.PageViews.names({:ticket, ticket.id})

    docs =
      MapSet.size(pages) +
        Enum.count(Artifacts.list(ticket.id), fn artifact ->
          not ForgeWeb.PageViews.member?(pages, artifact.name) and
            doc?(%{artifact: artifact, latest: Artifacts.latest(ticket.id, artifact.name)})
        end)

    strip(
      project,
      ticket,
      %{
        changes: Diff.file_count(branch_diff(project, ticket)),
        docs: docs,
        activity: activity
      },
      talk(step(ticket), Conversations.summaries(ticket_id: ticket.id)),
      :navigate
    )
  end

  defp step(%{status: status} = ticket) when status in [:active, :stuck] do
    with true <- Forge.Steps.step?(ticket),
         %Jobs.Job{} = chat <- Forge.Steps.chat_for(ticket),
         do: %{chat: chat},
         else: (_no_step -> nil)
  end

  defp step(_ticket), do: nil

  defp branch_diff(project, ticket) do
    repo = Projects.repo_path(project)

    case Git.resolve(repo, "refs/heads/" <> ticket.branch) do
      {:ok, head} -> Diff.build(repo, ticket.base_commit, head)
      _gone -> nil
    end
  end

  @doc """
  The conversation Talk opens: the chat step's while the ticket rests in one, else the most
  recently used live conversation about the ticket (`summaries` in the list's order), or nil.
  """
  @spec talk(map() | nil, [map()]) :: map() | nil
  def talk(%{chat: chat}, _summaries), do: chat

  def talk(_step, summaries) do
    case Enum.find(summaries, & &1.live) do
      %{chat: chat} -> chat
      nil -> nil
    end
  end

  @doc """
  Whether an artifact entry (`%{artifact, latest}`) is one of the ticket's Docs: written at least
  once, and not the changeset, which is Changes'. What Docs lists and what its count counts.
  """
  @spec doc?(map()) :: boolean()
  def doc?(%{artifact: artifact, latest: latest}),
    do: latest != nil and artifact.name != Workflow.changeset_artifact()

  # -- ways forward --------------------------------------------------------------------------

  @doc """
  The ways forward from where the ticket rests (`ui.md` § Steps): a transition the person may take
  to each state offered, and *Run `<state>` again* when the state can be run again — each with
  where it leads and what it starts. None while an approval waits, questions block, the merge
  queue holds the ticket or a chat step's conversation is live: those have their own ways on.
  """
  @spec ways(map()) :: [%{value: String.t(), label: String.t(), detail: String.t()}]
  def ways(%{workflow: workflow, ticket: ticket} = assigns) do
    moves =
      if moves?(assigns),
        do:
          for(
            to <- assigns.transitions,
            do: %{value: "to:" <> to, label: "Move to #{to}", detail: leads(workflow, to)}
          ),
        else: []

    extend =
      if assigns.retry and Map.get(assigns, :extend),
        do: [
          %{
            value: "extend",
            label: "Extend #{ticket.state}",
            detail: "the same job carries on with its session, on the room you give it"
          }
        ],
        else: []

    again =
      if assigns.retry,
        do: [
          %{
            value: "again",
            label: "Run #{ticket.state} again",
            detail: "a new job in #{ticket.state}, from what it was handed last time"
          }
        ],
        else: []

    moves ++ extend ++ again
  end

  # Where a way forward may be offered at all: nothing waits on a decision, a question, the merge
  # line or a live conversation, which have their own ways on.
  defp resting?(assigns) do
    assigns.ticket.pending_transition == nil and blocking(assigns) == [] and
      assigns.queue == nil and not step_live?(assigns.step)
  end

  defp moves?(assigns),
    do: resting?(assigns) and (assigns.ticket.status == :stuck or assigns.human_state)

  @doc """
  The fold of **other states** under the ways forward (`ui.md` § Steps): every state of the pinned
  workflow that is not one of the arrows' targets, each a **jump** — a move no transition leads to,
  taking none and so recording none of its approvals. Drawn where the arrows are, and on a ticket
  that is done, which has no arrows and is reopened by one; never on a cancelled ticket, and not
  at all when there is no state to offer.

  `assigns.jumps` is what `ForgeWeb.TicketLive` read of each: its name, whether it merges and what
  its job would find missing (`Forge.Jobs.missing_inputs/3`, the rule creation uses). A row with
  something missing is listed and disabled and says what, and that a ticket chat can write it; one
  into a state that merges is drawn as the approval it records.
  """
  @spec fold(map()) :: [map()]
  def fold(%{workflow: workflow, ticket: ticket} = assigns) do
    if fold?(assigns) do
      for jump <- assigns.jumps do
        %{
          value: "jump:" <> jump.to,
          label: "Jump to #{jump.to}",
          detail: jump_detail(workflow, jump, assigns),
          disabled: missing_note(workflow, jump.missing),
          merges: jump.merges,
          ticket: ticket
        }
      end
    else
      []
    end
  end

  defp fold?(assigns) do
    # A cancelled ticket is neither stuck, in a human state (that is an *open* ticket's) nor done, so
    # `moves?/1` and this refuse it without a guard of their own: the fold is never drawn for it.
    assigns.jumps != [] and
      (moves?(assigns) or (resting?(assigns) and assigns.ticket.status == :done))
  end

  defp jump_detail(_workflow, %{merges: true}, assigns) do
    "merges, approving the changeset#{approving(assigns.changeset)} in your name" <>
      stat(assigns.diff) <> " · no transition leads here"
  end

  defp jump_detail(workflow, %{to: to}, _assigns), do: leads_by_jump(workflow, to)

  defp leads_by_jump(workflow, to), do: leads(workflow, to) <> "; no transition leads here"

  defp approving(%{version: version}), do: " v#{version}"
  defp approving(_none), do: ""

  defp stat(%{added: added, removed: removed, files: files}) when is_list(files),
    do:
      " · +#{added} −#{removed} in #{length(files)} #{if length(files) == 1, do: "file", else: "files"}"

  defp stat(_none), do: ""

  # What stops a jump from being taken from the page: the page writes no document, so what is
  # missing is said with who can write it (`ui.md` § Steps).
  defp missing_note(_workflow, []), do: nil

  defp missing_note(workflow, names) do
    made = [Workflow.changeset_artifact(), Workflow.commit_message_artifact()]
    {produced, written} = Enum.split_with(names, &(&1 in made))

    Enum.join(
      Enum.reject(
        [
          written != [] &&
            "#{Enum.join(written, ", ")} has no version yet — a ticket chat can write it",
          produced != [] && produced_by(workflow, produced)
        ],
        &(&1 == false)
      ),
      "; "
    )
  end

  defp produced_by(workflow, names) do
    Enum.map_join(names, "; ", fn name ->
      case Workflow.producers(workflow, name) do
        [] -> "#{name} has no version yet"
        states -> "#{name} has no version yet — #{Enum.join(states, ", ")} writes it"
      end
    end)
  end

  # What taking the edge starts, in words: the state's kind decides it. Public because the queue
  # offers the same ways and says the same words (`ForgeWeb.QueueLive`).
  def leads(workflow, to) do
    case Workflow.state(workflow, to) do
      %Workflow.State{chat: true} -> "opens a conversation there, waiting for a person"
      %Workflow.State{prompt: prompt} when is_binary(prompt) -> "starts a job in #{to}"
      %Workflow.State{invoke: [_ | _]} -> "runs #{to}'s commands"
      %Workflow.State{} = state -> leads_without_work(state)
      nil -> "rests there for a person"
    end
  end

  # What a state with no job does on entry: the platform's own work, or nothing but wait.
  defp leads_without_work(%Workflow.State{} = state) do
    cond do
      Workflow.State.merges?(state) -> "merges the ticket's branch"
      Workflow.State.updates?(state) -> "brings the branch up to date, then moves on"
      true -> "rests there for a person"
    end
  end

  # No by-hand transition is offered while a step's conversation is live: Accept is the way out
  # (`docs/design/conversations.md` § A conversation that is a step).
  defp step_live?(%{current: true, live: true}), do: true
  defp step_live?(_step), do: false

  defp blocking(%{questions: {blocking, _assumed}}), do: blocking

  # One form per document version (`docs/design/ui.md` § The question card). A version holding a
  # blocking question is waiting, and its assumptions join its form, optional; a version with only
  # assumptions is answered beneath Steps, where nothing waits on it. Oldest version first.
  defp forms(%{questions: {blocking, assumed}}, which) do
    {joined, alone} = QuestionForm.join_assumed(blocking, assumed)
    questions = if which == :waiting, do: blocking ++ joined, else: alone

    questions
    |> Enum.group_by(& &1.artifact_version_id)
    |> Enum.sort_by(fn {_version, [first | _]} -> first.inserted_at end, DateTime)
  end

  # -- the dock ------------------------------------------------------------------------------

  @doc """
  Whether the dock above the strip has anything: the question pane while a document's questions
  block, the way forward's button on Steps, or the running job's chip while nothing waits.
  """
  @spec dock?(map()) :: boolean()
  def dock?(assigns),
    do: questions?(assigns) or button?(assigns) or chip?(assigns) or questions_gone?(assigns)

  defp questions?(assigns),
    do: assigns.ticket.pending_transition == nil and blocking(assigns) != []

  defp button?(assigns),
    do: assigns.view == "steps" and (assigns.ways != [] or assigns.fold != [])

  # With nothing waiting, the job running now is a quiet chip that opens its page (`5d`) — on
  # Changes and Docs. Steps and Activity lead with the job's own row, which says the same thing a
  # line above (UX pass, B27).
  defp chip?(%{current: %{status: status}, decision: nil, view: view} = assigns)
       when status in [:pending, :running, :waiting, :parked] and view not in ~w(steps activity),
       do: not questions?(assigns) and not button?(assigns)

  defp chip?(_assigns), do: false

  # A question card's Send refused, with no card left in the pane to draw it — the questions were
  # answered in another tab before the press arrived. An assumed question's card draws its own.
  defp questions_gone?(%{refusal: %{at: {:form, id}}} = assigns),
    do: not questions?(assigns) and not List.keymember?(forms(assigns, :assumed), id, 0)

  defp questions_gone?(_assigns), do: false

  defp picked_merge?(fold, forward), do: Enum.any?(fold, &(&1.value == forward and &1.merges))

  @doc "The dock: the question pane, the way forward's button, or the job's chip."
  def dock(assigns) do
    assigns =
      assign(assigns,
        pane: questions?(assigns),
        dock_button: button?(assigns),
        job_chip: chip?(assigns),
        picked: Enum.find(assigns.ways ++ assigns.fold, &(&1.value == assigns.forward))
      )

    ~H"""
    <%!-- The questions sit above the strip on every view, so a person reading Docs or Changes
          answers them from where they are; they scroll inside the pane, which is bounded. --%>
    <%!-- A Send refused whose card has gone since — the questions answered in another tab — is
          drawn where the pane stood, as `#decision-gone` is for the row. --%>
    <Actions.refused
      :if={questions_gone?(assigns)}
      id="questions-gone-refusal"
      refusal={@refusal}
      at={[:questions]}
    />
    <div :if={@pane} id="question-pane" class="ticket-questions">
      <.question_form
        :for={{version_id, questions} <- forms(assigns, :waiting)}
        id={version_id}
        questions={questions}
        forms={@forms}
        refusal={@refusal}
        submit="questions:send"
        project={@project.name}
        hidden={[{"ticket", @ticket.id}, {"version", version_id}]}
      />
    </div>
    <%!-- Under the thumb on a phone; from 768 the step draws it under the choices it commits
          (`#forward-inline`), and this one is hidden (UX pass, B1). --%>
    <div :if={@dock_button and not @pane} class="ticket-dock ticket-dock--forward">
      <.forward_button id="forward-button" picked={@picked} />
    </div>
    <div :if={@job_chip} class="ticket-dock ticket-dock--chip">
      <.link
        id="job-chip"
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@current.id}"}
        class="ticket-job-chip"
      >
        ▸ {@current.state} #{@current.attempt} · {@current.status}
      </.link>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :picked, :map, default: nil

  # The one button that takes the way picked: the dock's on a phone, under the choices from 768.
  # Nothing is picked until a person picks it, so until then it says so and does nothing.
  defp forward_button(assigns) do
    ~H"""
    <button
      type="submit"
      form="ways-forward"
      id={@id}
      disabled={is_nil(@picked) or @picked[:disabled] != nil}
      phx-disable-with="Sending…"
      class="ui-btn ui-btn--primary ui-btn--lg ui-btn--fill"
    >
      {if @picked, do: @picked.label, else: "Pick a way forward"}
    </button>
    """
  end

  # -- the wide screen's column -----------------------------------------------------------------

  @doc """
  Whether a wide screen has a document to put beside the view: the one the decision waits on,
  rendered (`16i`). Drawn at every width and shown only from 1440px, by CSS.
  """
  @spec aside?(map()) :: boolean()
  def aside?(assigns), do: aside_doc(assigns) != nil

  # A step's Accept names its own document (`StepAccept.aside_doc_name/1`, the conversation's page
  # asks the same); an approval, the first document it waits on that has something to render.
  defp aside_doc(%{docs: docs, decision: %{kind: :step, step: step}}) do
    name = StepAccept.aside_doc_name(step)
    Enum.find(docs, &(&1.name == name and &1.latest.body != nil))
  end

  defp aside_doc(%{docs: docs}),
    do: Enum.find(docs, &(&1[:group] == :waiting and &1.latest.body != nil))

  @doc "The document the decision waits on, read beside the view on a wide screen."
  def aside(assigns) do
    assigns = assign(assigns, :doc, aside_doc(assigns))

    ~H"""
    <article id="aside-document" class="ticket-aside">
      <header class="ticket-aside-head">
        <span class="font-mono">{@doc.name} v{@doc.latest.version}</span>
        <.link href={@doc.latest.href} class="text-link">Open ›</.link>
      </header>
      <FileType.document_body body={@doc.latest.body} />
    </article>
    """
  end

  # -- the release band ------------------------------------------------------------------------

  @doc """
  The slim band a release ticket carries under its top bar (`21e`): what it is, who started it and
  the workflow it runs. Not a decision row — no button, no amber.
  """
  attr :ticket, :map, required: true
  attr :release, :map, required: true

  def release_band(assigns) do
    ~H"""
    <div id="release-band" class="ticket-release">
      <.type_icon kind="release" />
      <span>Release · started by {starter(@release.by)}</span>
      <span :if={@ticket.ticket_type} class="ticket-release-file">{@ticket.ticket_type}.yml</span>
    </div>
    """
  end

  @doc """
  The band a ticket on hold carries where a status goes (`docs/design/ui.md` § The ticket): the
  words *on hold*, what releasing does, **Release**, and **Stop now** while a run of its state is
  still going. Neutral, never amber: nothing waits on you, because nothing moves until you say so.
  """
  attr :ticket, :map, required: true
  attr :on_release, :any, required: true
  attr :stoppable, :boolean, required: true
  attr :refusal, :map, default: nil

  def hold_band(assigns) do
    ~H"""
    <div id="hold-band" class="ticket-hold">
      <div class="ticket-hold-line">
        <span class="ticket-hold-word">On hold</span>
        <span :if={on_release_words(@on_release)} id="hold-waits" class="ticket-hold-waits">
          {on_release_words(@on_release)}
        </span>
      </div>
      <div class="ticket-hold-actions">
        <.button
          id="release-ticket"
          type="button"
          variant="outline"
          size="md"
          phx-click="release-ticket"
          phx-value-ticket={@ticket.id}
        >
          Release
        </.button>
        <.confirm
          :if={@stoppable}
          id="stop-now"
          label="Stop now"
          act="Stop it"
          sentence="Stop the run now? What it spent is counted, and the state runs again when you release."
          tone="neutral"
          size="md"
          phx-click="stop-now"
          phx-value-ticket={@ticket.id}
        />
      </div>
      <Actions.refused id="hold-refusal" refusal={@refusal} at={~w(release-ticket stop-now)} />
    </div>
    """
  end

  defp on_release_words({:transition, _from, to, _outcome}), do: "moves to #{to} when released"
  defp on_release_words({:entry, state}), do: "starts #{state} when released"
  defp on_release_words(nil), do: nil

  # The current step's dot (`ui.md` § Colour): amber only while the ticket waits on a person — it
  # is stuck, a decision row is drawn, or a job in the step stopped to ask — info while something
  # runs in it, muted once the ticket is in a terminal state, ink otherwise.
  # An equivalent mutant: Steps always ends on the ticket's current state, so there is a last step.
  defp current_dot(nil, _assigns), do: "still"

  defp current_dot(step, assigns) do
    cond do
      assigns.ticket.status == :stuck or assigns[:decision] != nil or
          Enum.any?(step.jobs, &(&1.status == :waiting)) ->
        "waiting"

      step[:topology] == :terminal ->
        "ended"

      Enum.any?(step.jobs, &(&1.status in [:pending, :running, :parked])) ->
        "running"

      true ->
        "still"
    end
  end

  defp starter(%{"kind" => "user"}), do: "a person"
  defp starter(actor), do: Format.author(actor) || "the platform"

  # -- Steps ---------------------------------------------------------------------------------

  @doc """
  Steps (`ui.md` § Steps, `5g`): a step per visit on the line-and-dot, the current one open with
  what waits there, the done ones folded; then the merge queue's part of the story, what an agent
  assumed, and the ticket's conversations.
  """
  def steps(assigns) do
    assigns =
      assign(assigns,
        last: length(assigns.steps) - 1,
        dot: current_dot(List.last(assigns.steps), assigns)
      )

    ~H"""
    <.release_lead :if={@release} ticket={@ticket} release={@release} project={@project} />
    <p
      :if={!@release and @ticket.body != ""}
      id="ticket-body"
      class="mb-5 text-sm/[1.55] whitespace-pre-line break-words text-ink-2"
    >
      {@ticket.body}
    </p>
    <ForgeWeb.UI.Attach.names
      :if={!@release}
      files={@ticket_files}
      path={& &1.href}
      class="mb-5"
    />

    <ol id="steps-list" class="ticket-steps">
      <li
        :for={{step, i} <- Enum.with_index(@steps)}
        id={"step-#{i}"}
        class={[
          "ticket-step",
          step[:jump] && "ticket-step--jump",
          i == @last && ["ticket-step--current", "ticket-step--#{@dot}"]
        ]}
      >
        <p :if={step[:jump]} class="ticket-step-jump text-sm/[1.45] text-ink-2 break-words">
          <span class="ticket-step-dot" aria-hidden="true" />
          <span class="min-w-0">
            Jumped from {step.jump.from} to {step.jump.to}, with no transition{if step.jump.reopened,
              do: " (reopened)"} · {step.jump.by}<span :if={step.jump.comment}>: {String.slice(
              step.jump.comment,
              0,
              160
            )}</span>
          </span>
        </p>
        <details :if={!step[:jump]} open={i == @last} phx-mounted={keep_open()}>
          <summary class="ticket-step-row">
            <span class="ticket-step-dot" aria-hidden="true" />
            <.state name={step.name} topology={step.topology} />
            <.step_outcome step={step} accepted={@accepted} />
            <span class="ticket-step-detail">{step_detail(step, i == @last, @ticket)}</span>
          </summary>
          <div class="ticket-step-body">
            <.step_jobs step={step} {assigns} />
            <.update_visit :if={step[:update]} step={step} />
            <div :if={step.artifacts != []} class="mt-2 flex flex-wrap gap-2">
              <.artifact_chip
                :for={entry <- step.artifacts}
                entry={entry}
                project={@project.name}
                number={@ticket.number}
              />
            </div>
            <.current_step :if={i == @last} {assigns} />
          </div>
        </details>
      </li>
    </ol>

    <%!-- The merge queue's part of the ticket's story: queued, back in line after an integration,
          taken out, merged, left — in Activity's words (`ui.md` § Steps). --%>
    <section :if={@queue_events != []} id="queue-history" class="ticket-section">
      <.eyebrow>Merge queue</.eyebrow>
      <ol class="mt-3 flex flex-col gap-1.5 text-sm/[1.45]">
        <li :for={event <- @queue_events} class="flex gap-3">
          <span class="shrink-0 font-mono text-[12.5px] text-ink-3">
            {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
          </span>
          <span class="min-w-0 break-words">
            {Forge.Events.summary(event)}<span
              :if={Format.author(event.actor)}
              class="text-ink-2"
            > · {Format.author(event.actor)}</span>
          </span>
        </li>
      </ol>
    </section>

    <%!-- What an agent assumed and carried on from: answerable here, where the queue's digest
          sends it, and drawn without accent because nothing waits on the answer. --%>
    <section :if={forms(assigns, :assumed) != []} id="assumed" class="ticket-section">
      <.eyebrow>Assumed, and carried on</.eyebrow>
      <div class="mt-3 flex flex-col gap-6">
        <.question_form
          :for={{version_id, questions} <- forms(assigns, :assumed)}
          id={version_id}
          questions={questions}
          forms={@forms}
          refusal={@refusal}
          any_refusal={false}
          submit="questions:send"
          project={@project.name}
          hidden={[{"ticket", @ticket.id}, {"version", version_id}]}
        />
      </div>
    </section>

    <%!-- A conversation started from a ticket was findable from the project page and not from
          the ticket it is about. Its order and sections are the component's. --%>
    <section id="ticket-chats" class="ticket-section">
      <div class="flex items-center justify-between gap-3">
        <.eyebrow>Conversations</.eyebrow>
        <.link
          navigate={~p"/chats/new?project=#{@project.name}&ticket=#{@ticket.number}"}
          class="flex min-h-[46px] items-center text-sm text-link hover:underline"
        >
          New chat ›
        </.link>
      </div>
      <ForgeWeb.Conversations.list
        summaries={@chats}
        now={@now}
        project={false}
        heading="h3"
        empty="No conversation about this ticket yet."
      />
    </section>
    """
  end

  attr :step, :map, required: true

  # What an update step's visit did, opened: the sentence, the merges it brought in by ticket
  # number (a conversation's said as such), at most ten and *and N more*, and the re-pin under it
  # (`docs/design/ui.md` § Steps). Every value is a contributor's and is drawn as text.
  defp update_visit(assigns) do
    payload = assigns.step.update

    assigns =
      assign(assigns,
        said: Forge.Update.said(payload),
        repin: Forge.Update.repin_said(payload),
        merges: payload["merges"] || [],
        more: payload["more"] || 0,
        titles: assigns.step[:titles] || %{}
      )

    ~H"""
    <div id={"update-visit-#{@step.name}"} class="ticket-update">
      <p class="break-words text-sm/[1.45]">{@said}</p>
      <ol :if={@merges != []} class="ticket-update-merges">
        <li :for={merge <- @merges} class="truncate">
          <%= cond do %>
            <% merge["ticket"] -> %>
              <span class="font-mono text-ink-3">#{merge["ticket"]}</span> {@titles[merge["ticket"]] ||
                merge["subject"]}
            <% merge["chat"] -> %>
              a conversation's merge · {merge["subject"]}
            <% true -> %>
              {merge["subject"]}
          <% end %>
        </li>
        <li :if={@more > 0} class="text-ink-3">and {@more} more</li>
      </ol>
      <p :if={@repin} class="break-words text-[12.5px] text-ink-2">{@repin}</p>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :accepted, :map, required: true

  # How the visit ended, drawn as a job's row draws it: the last job's outcome, or what a chat
  # step was accepted with.
  defp step_outcome(assigns) do
    assigns = assign(assigns, :last, List.last(assigns.step.jobs))

    ~H"""
    <%= cond do %>
      <% @last == nil -> %>
      <% @last.kind == :chat and @accepted[@last.id] != nil -> %>
        <.outcome value={@accepted[@last.id]["outcome"]} />
      <% @last.kind == :workflow and (@last.declared_outcome || @last.outcome) != nil -> %>
        <.outcome
          value={@last.declared_outcome || to_string(@last.outcome)}
          bucket={@last.declared_outcome && bucket(@last.outcome)}
        />
      <% true -> %>
    <% end %>
    """
  end

  # The figure at a step's end: its jobs and what they spent; at a ticket's end, the whole. An update
  # step's visit says what it did in one line, as the folded row shows it (`ui.md` § Steps).
  defp step_detail(%{topology: :terminal}, true, ticket),
    do: if(spent = Format.spent(ticket.usage), do: "#{spent} total")

  defp step_detail(%{update: %{} = payload}, _current, _ticket), do: Forge.Update.said(payload)

  # A ticket resting in an update step with no visit recorded yet is on hold, or about to run it.
  defp step_detail(%{topology: :update, jobs: []}, true, %{held_at: held}) when held != nil,
    do: "brings the branch up to date when released"

  defp step_detail(%{topology: :update, jobs: []}, true, _ticket),
    do: "bringing the branch up to date"

  defp step_detail(%{jobs: []}, _current, _ticket), do: nil

  # What it spent is its own span, which a phone leaves out rather than cut to `0.08 win…`: the
  # figure is on each job's row beneath (UX re-check #19).
  defp step_detail(step, _current, _ticket) do
    assigns = %{jobs: Format.counted(length(step.jobs), "job"), spent: Format.spent(step.cost)}

    ~H"""
    {@jobs}<span :if={@spent} class="ticket-step-spent"> · {@spent}</span>
    """
  end

  # The whole row is the target, at the full 46px: hunting for a 20px `#3` is the failure
  # docs/design/ui.md § The affordance rule names. Nothing inside a job row commits anything, so
  # the row may be a link. One list in the order the work was made, so an agent's commands follow
  # the row of the agent that invoked them rather than all sitting above it.
  defp step_jobs(assigns) do
    ~H"""
    <ol :if={@step.jobs != []} class="ticket-jobs">
      <li :for={job <- @step.jobs}>
        <.command_row
          :if={job.kind == :command}
          job={job}
          project={@project}
          ticket={@ticket}
          wait={@waits[job.id]}
        />
        <%!-- `job.kind == :command` is an equivalent mutant: a batch's `commands.started`
              names only its command jobs, which is all `failure_tails/2` keys by. --%>
        <pre
          :if={job.kind == :command and @tails[job.id]}
          id={"command-#{job.id}-tail"}
          class="ticket-tail"
        >{@tails[job.id]}</pre>
        <.link
          :if={job.kind == :chat}
          id={"step-chat-#{job.id}"}
          navigate={~p"/chats/#{job.id}"}
          class="ticket-job"
        >
          <span class="w-8 shrink-0 font-mono">#{job.attempt}</span>
          <span class="min-w-0 flex-1 text-sm">
            <span class="block truncate">Conversation</span>
            <span id={"job-#{job.id}-harness"} class="ticket-job-harness">
              {Forge.Jobs.harness_line(job, @project)}
            </span>
            <%!-- The outcome drawn with the component a job's row uses (`.outcome`), cut to
                  the line: the outcome is the workflow author's word. --%>
            <span :if={@accepted[job.id]} id={"step-accepted-#{job.id}"} class="block truncate">
              <.outcome value={@accepted[job.id]["outcome"]} />
              <span class="text-ink-2">→ {@accepted[job.id]["to"]}</span>
            </span>
            <.job_status :if={!@accepted[job.id]} status={job.status} />
            <span
              :if={@waits[job.id]}
              id={"job-#{job.id}-waiting"}
              class="block text-sm/[1.4] text-ink-2 [overflow-wrap:anywhere]"
            >
              {@waits[job.id]}
            </span>
          </span>
          <span class="shrink-0 font-mono text-ink-2">{Format.counted(job.turns, "turn")}</span>
          <span class="ticket-job-spent" title={Format.exact(job.usage)}>
            {Format.spent(job.usage)}
          </span>
          <span class="shrink-0 font-mono text-ink-3" aria-hidden="true">›</span>
        </.link>
        <.link
          :if={job.kind == :workflow}
          id={"job-row-#{job.id}"}
          navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
          class="ticket-job"
        >
          <span class="w-8 shrink-0 font-mono">#{job.attempt}</span>
          <span class="ticket-job-main">
            <%!-- The outcome and what it ran out of stay on one line: wrapped, `· turns` sat
                  under `budget_exhausted` as if it were a second fact (UX re-check #19). --%>
            <span class="ticket-job-outcome">
              <.outcome
                :if={job.declared_outcome || job.outcome}
                value={job.declared_outcome || to_string(job.outcome)}
                bucket={job.declared_outcome && bucket(job.outcome)}
              />
              <.job_status :if={is_nil(job.outcome)} status={job.status} />
              <.ceiling job={job} />
            </span>
            <span id={"job-#{job.id}-harness"} class="ticket-job-harness">
              {Forge.Jobs.harness_line(job, @project)}
            </span>
            <%!-- Language, not an identifier: sans at body size, and never accent — a
                  machine is being waited on, not the operator. --%>
            <span
              :if={@waits[job.id]}
              id={"job-#{job.id}-waiting"}
              class="block text-sm/[1.4] text-ink-2"
            >
              {@waits[job.id]}
            </span>
          </span>
          <%!-- The figures wrap together, under the outcome, when the two do not fit. --%>
          <span class="ticket-job-figures">
            <span class="shrink-0 font-mono text-ink-2">{Format.counted(job.turns, "turn")}</span>
            <span class="ticket-job-spent" title={Format.exact(job.usage)}>
              {Format.spent(job.usage)}
            </span>
            <span class="shrink-0 font-mono text-ink-3" aria-hidden="true">›</span>
          </span>
        </.link>
      </li>
    </ol>
    """
  end

  # `docs/design/ui.md` § Steps: `$` where an attempt goes, the command and its arguments, the
  # exit status where an outcome goes, the duration where turns and cost go. One an agent invoked
  # is indented beneath it.
  attr :job, :map, required: true
  attr :project, :map, required: true
  attr :ticket, :map, required: true
  attr :wait, :string, default: nil

  def command_row(assigns) do
    command = Jobs.spec(assigns.job).command
    assigns = assign(assigns, name: command["name"], args: command["args"] || [])

    ~H"""
    <.link
      navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@job.id}"}
      id={"command-#{@job.id}"}
      class={["ticket-job", @job.parent_job_id && "pl-8"]}
    >
      <span class="w-8 shrink-0 font-mono text-ink-2" aria-hidden="true">$</span>
      <span class="min-w-0 flex-1">
        <span class="font-mono">
          {@name}<span :if={@args != []} class="text-ink-2">{ForgeCore.Workflow.Command.argv(@args)}</span>
        </span>
        <.exit_status job={@job} />
        <span :if={@wait} id={"job-#{@job.id}-waiting"} class="block text-sm/[1.4] text-ink-2">
          {@wait}
        </span>
      </span>
      <span class="shrink-0 font-mono text-ink-2">{Format.duration(@job)}</span>
      <span class="shrink-0 font-mono text-ink-3" aria-hidden="true">›</span>
    </.link>
    """
  end

  # What waits at the step the ticket is in, in the order a person meets it: why it stuck, a chat
  # step's conversation, the approval pinned above, the merge queue, a human state's documents and
  # the ways forward.
  defp current_step(assigns) do
    ~H"""
    <div class="ticket-current">
      <p :if={@ticket.status == :stuck} id="stuck-reason" class="text-sm/[1.55] text-accent-text">
        {if @stuck_reason,
          do: "Stuck: #{@stuck_reason}. Waiting for you to choose.",
          else: "Stuck, and waiting for you to choose."}
      </p>

      <%!-- A chat step: this step is a conversation, and Accept is how it ends. --%>
      <div :if={@step} id="step-card" class="flex flex-col gap-3">
        <p class="min-w-0 break-words text-sm">
          This step is a conversation.
          <.link navigate={~p"/chats/#{@step.chat.id}"} class="text-link hover:underline">
            Talk to the agent ›
          </.link>
        </p>
        <p
          :if={@waits[@step.chat.id]}
          id="step-waiting-reason"
          class="min-w-0 text-sm text-ink-2 [overflow-wrap:anywhere]"
        >
          {@waits[@step.chat.id]}
        </p>
        <StepAccept.status step={@step} />
      </div>

      <%!-- The approval itself is the row pinned above, on every view: read Changes or Docs and
            decide from where you are (`docs/design/ui.md` § The decision row). --%>
      <p :if={@ticket.pending_transition} id="approval-pinned" class="text-sm/[1.55] text-ink-2">
        Waiting on your approval of {Enum.map_join(
          @decision.pins,
          ", ",
          &"#{&1.name} v#{&1.version}"
        )}. Approve or reject it from the row above.
      </p>

      <%!-- Where the approval stood: approving a queueing edge puts the ticket in line, and the
            card says so instead of offering to approve what is approved. --%>
      <.merge_queue_card :if={@queue} ticket={@ticket} place={@queue} />
      <Actions.refused id="take-out-refusal" refusal={@refusal} at={["take-out"]} />

      <%!-- A human state's documents, above its ways forward: the person deciding where the
            ticket goes next is the one the next job needs to hear from. --%>
      <div
        :if={!@ticket.pending_transition and @writable != []}
        id="writable"
        class="flex flex-col gap-6"
      >
        <.document_editor
          :for={{name, latest} <- @writable}
          ticket={@ticket}
          name={name}
          latest={latest}
          drafts={@drafts}
          project={@project.name}
        />
      </div>
      <%!-- Outside the editors: a Save refused because an approval arrived meanwhile finds them
            gone after the reload, and the refusal must still be drawn. --%>
      <Actions.refused id="write-refusal" refusal={@refusal} at={["write_document"]} />

      <%!-- A choice row each; the dock's button takes the one picked. Nothing is picked until a
            person picks it, so the button says so and does nothing. --%>
      <form
        :if={@ways != [] or @fold != []}
        id="ways-forward"
        phx-change="forward:pick"
        phx-submit="forward"
        class="flex flex-col gap-2"
      >
        <.eyebrow :if={@ways != []}>Ways forward</.eyebrow>
        <%= for way <- @ways do %>
          <.choice_row
            id={"way-#{way.value}"}
            name="way"
            value={way.value}
            label={way.label}
            detail={way.detail}
            selected={@forward == way.value}
          />
          <%!-- Its fields, under the row picked: the form is one, so the one button submits them
                on a phone and on a laptop alike (`ui.md` § Steps, *Ways forward*). --%>
          <MoreRoom.fields
            :if={@forward == way.value and way.value in ~w(extend again)}
            way={way.value}
            offer={@extend}
            room={@room}
            drafts={@drafts}
            draft="ways-forward"
            prefix="forward"
            project={@project.name}
          />
        <% end %>
        <%!-- Other states: each a jump, which takes no transition. The fold is a checkbox of this
              form, so what the client replays on a rejoin opens it and picks the row together
              (`ui.md` § A reconnect is not a reload). --%>
        <div :if={@fold != []} id="ways-other" class="flex flex-col gap-2">
          <label
            for="ways-other-toggle"
            class="flex min-h-[46px] cursor-pointer items-center gap-2 text-sm text-ink-2 hover:text-ink"
          >
            <input
              id="ways-other-toggle"
              type="checkbox"
              name="other"
              value="open"
              checked={@other}
              class="sr-only"
            />
            <span aria-hidden="true">{if @other, do: "▾", else: "▸"}</span>
            Other states ({length(@fold)})
          </label>
          <.choice_row
            :for={way <- if(@other, do: @fold, else: [])}
            id={"way-#{way.value}"}
            name="way"
            value={way.value}
            label={way.label}
            detail={way.disabled || way.detail}
            selected={@forward == way.value}
            disabled={way.disabled != nil}
          />
          <Decision.commit_block
            :if={@other and picked_merge?(@fold, @forward)}
            id="jump-commit"
            commit={Decision.commit_of(@ticket)}
          />
        </div>
      </form>
      <%!-- From 768 the button sits under the choices it commits, not a screen away in the
            dock (UX pass, B1); the dock keeps it on a phone, under the thumb. --%>
      <div :if={@ways != [] or @fold != []} id="forward-inline" class="ticket-forward-inline">
        <.forward_button
          id="forward-button-inline"
          picked={Enum.find(@ways ++ if(@other, do: @fold, else: []), &(&1.value == @forward))}
        />
      </div>
      <%!-- Under the ways forward, and drawn without them too: a way sent from a page drawn
            before the ticket moved is refused after they have gone. --%>
      <Actions.refused id="forward-refusal" refusal={@refusal} at={~w(retry extend transition)} />
    </div>
    """
  end

  # The release's note and what has merged since the last one lead its Steps (`21e`).
  attr :ticket, :map, required: true
  attr :release, :map, required: true
  attr :project, :map, required: true

  defp release_lead(assigns) do
    ~H"""
    <section id="release-lead" class="mb-6 flex flex-col gap-4">
      <div :if={@ticket.body != ""}>
        <.eyebrow>The note</.eyebrow>
        <p class="mt-2 text-[15px]/[1.55] whitespace-pre-line break-words">{@ticket.body}</p>
      </div>
      <div :if={@release.since} id="release-since">
        <.eyebrow>Since {@release.since.version}</.eyebrow>
        <p :if={@release.since.tickets == []} class="mt-2 text-sm text-ink-2">
          Nothing has merged since.
        </p>
        <.link
          :for={t <- @release.since.tickets}
          navigate={~p"/tickets/#{@project.name}/#{t.number}"}
          class="ticket-since-row"
        >
          <span class="font-mono text-ink-3">#{t.number}</span>
          <span class="min-w-0 truncate">{t.title}</span>
        </.link>
      </div>
    </section>
    """
  end

  # There is no chip without a version: approval attaches to an exact version, and a human edit
  # creating v3 does not carry v2's approval. A presentation has no approval slot at all, and
  # neither has an artifact the pinned workflow never approves — see docs/design/ui.md.
  #
  # The chip is a link to the exact version's bytes, which is also why it is bordered: a border
  # means you can tap it. A changeset is a commit rather than a file and the controller sends it
  # to the review page, where a diff is rendered.
  attr :entry, :map, required: true
  attr :project, :string, required: true
  attr :number, :integer, required: true

  defp artifact_chip(assigns) do
    ~H"""
    <.link
      :if={@entry.latest}
      href={
        ~p"/tickets/#{@project}/#{@number}/artifacts/#{@entry.artifact.name}/#{@entry.latest.version}"
      }
      class={[
        "ticket-chip",
        @entry.artifact.kind == :presentation && "ticket-chip--dashed"
      ]}
    >
      <FileType.file_icon artifact={@entry.artifact} size={:chip} />
      {@entry.artifact.name}
      <span class="text-ink-2">v{@entry.latest.version}</span>
      <span :if={@entry.artifact.kind == :presentation} class="uppercase text-ink-3">
        view only
      </span>
      <span :if={@entry.approvable and @entry.approved} class="text-success">✓ approved</span>
      <span :if={@entry.approvable and not @entry.approved} class="text-accent-text">◇ unapproved</span>
    </.link>
    """
  end

  # -- Activity ------------------------------------------------------------------------------

  @doc """
  Activity (`ui.md` § Activity, `5d`): the current job's stream, newest first and live; what was
  decided and moved on the ticket itself, a rejection with its note; and the earlier jobs, each
  leading to its page.
  """
  def activity(assigns) do
    ~H"""
    <p :if={is_nil(@current)} class="text-sm text-ink-2">No job has run on this ticket.</p>

    <div :if={@current}>
      <.link
        id="activity-job"
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@current.id}"}
        class="mb-3 flex min-h-[46px] items-center font-mono text-[12.5px] hover:underline"
      >
        {@current.state} #{@current.attempt} ›
      </.link>
      <%!-- The stream in a bounded box of its own, so that reaching its end loads the next page
            there and does not push *On the ticket* and the earlier jobs away for good
            (`docs/design/ui.md` § Activity). --%>
      <div
        id="activity-pane"
        data-load-root
        class="max-h-[70vh] overflow-y-auto overscroll-contain"
      >
        <WorkScreen.activity
          stream={@activity}
          since={@since}
          heading={WorkScreen.stream_heading(@current, @activity.count)}
          hrefs={WorkScreen.version_hrefs(@docs)}
          transcripts={@transcripts}
        />
      </div>
      <span id="stream-reach" hidden data-activity={ForgeWeb.JobStream.reach_of(@activity)}></span>
    </div>

    <section :if={@events != []} id="ticket-events" class="ticket-section">
      <.eyebrow>On the ticket</.eyebrow>
      <ol class="mt-3 flex flex-col">
        <li :for={event <- @events} id={"ticket-event-#{event.seq}"} class="work-act">
          <div class="work-act-main">
            <span class="work-act-type">{event.type}</span>
            <div class="work-act-detail">
              {said(event)}
              <span :if={made_by(event, @current_scope.user.id, @addresses)} class="text-ink-2">
                · {made_by(event, @current_scope.user.id, @addresses)}
              </span>
              <ForgeWeb.UI.Attach.names
                files={Map.get(@attached_events, event.seq, [])}
                path={
                  &~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{&1.name}/#{&1.version}"
                }
              />
            </div>
          </div>
          <span class="work-act-time">{Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}</span>
        </li>
      </ol>
    </section>

    <section :if={length(@jobs) > 1} id="earlier-jobs" class="ticket-section">
      <.eyebrow>Earlier jobs</.eyebrow>
      <ul class="mt-3 flex flex-col">
        <li :for={job <- @jobs |> Enum.drop(-1) |> Enum.reverse()}>
          <.link
            navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
            class="ticket-job font-mono"
          >
            <span class="min-w-0 flex-1 truncate">{job.state} #{job.attempt}</span>
            <%!-- Through `Indicators`, like every other row: `ui.md` § The three axes says
                  nothing else may draw a job outcome. --%>
            <span class="shrink-0">
              <.outcome :if={job.outcome} value={to_string(job.outcome)} />
              <.job_status :if={is_nil(job.outcome)} status={job.status} />
            </span>
            <.ceiling job={job} />
            <span class="shrink-0 text-ink-3" aria-hidden="true">›</span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  @doc "What a ticket event says in words: its summary, which for a decision includes the note."
  @spec said(map()) :: String.t()
  def said(event), do: Forge.Events.summary(event)

  # -- the details ---------------------------------------------------------------------------

  @doc """
  The ticket's details, dropped from its title (`ui.md` § The details, `6d`): what it is, what it
  has spent of its allowance, its facts and pin, the notices that are true of it now, what its
  jobs proposed, and its lifecycle.
  """
  def details(assigns) do
    visits = Enum.count(assigns.steps, &(&1[:name] == assigns.ticket.state))
    assigns = assign(assigns, :visits, visits)

    ~H"""
    <div id="ticket-details" class="ticket-details">
      <div>
        <p class="ticket-details-title">{@ticket.title}</p>
        <p class="ticket-details-sub">
          {@project.name}#{@ticket.number}<span :if={@ticket.ticket_type} id="ticket-type"> · {@ticket.ticket_type}</span>
          · admitted {admitted(@ticket.inserted_at, @now)}
        </p>
        <%!-- Admitted by a clock, not a person's hand: which schedule, the time it was due, and the
              admin whose name it was admitted in. Text, as every word out of a file is. --%>
        <p :if={@scheduled} id="ticket-scheduled" class="ticket-details-sub">
          Admitted by the schedule <span class="font-mono">{@scheduled.name}</span>, due {@scheduled.due}<span :if={
            @scheduled.by
          }>, in {@scheduled.by}'s name</span>.
        </p>
      </div>

      <%!-- A title a member may change in any state, except a release's, which is its version. The
            draft survives a reconnect (`docs/design/ui.md` § A reconnect is not a reload). --%>
      <form
        :if={not Forge.ReleaseTickets.release?(@ticket)}
        id="retitle-form"
        phx-change="draft:change"
        phx-submit="retitle"
        class="ticket-retitle"
      >
        <input type="hidden" name="draft" value="retitle" />
        <input type="hidden" name="ticket" value={@ticket.id} />
        <label class="ticket-retitle-field">
          <span class="ui-field-label">Title</span>
          <input
            type="text"
            name="title"
            class="ui-field-input"
            autocomplete="off"
            value={ForgeWeb.Operator.Drafts.field(@drafts, "retitle", "title", @ticket.title)}
          />
        </label>
        <.button type="submit" variant="outline" size="md">Save title</.button>
      </form>
      <p :if={Forge.ReleaseTickets.release?(@ticket)} id="retitle-why" class="ticket-details-sub">
        A release's title is its version, set by the release itself, so it is not edited here.
      </p>

      <form
        :if={
          @ticket.status in Forge.Tickets.Ticket.open_statuses() and
            (@milestones != [] or @ticket.milestone_id)
        }
        phx-change="set-milestone"
        phx-auto-recover="ignore"
        class="ticket-milestone-form"
      >
        <input type="hidden" name="ticket" value={@ticket.id} />
        <label class="ticket-retitle-field">
          <span class="ui-field-label">Milestone</span>
          <select name="milestone" id="ticket-milestone" class="ui-field-input">
            <option value="" selected={@ticket.milestone_id == nil}>None</option>
            <option :for={m <- @milestones} value={m.id} selected={m.id == @ticket.milestone_id}>
              {m.name}
            </option>
          </select>
        </label>
      </form>

      <div id="ticket-usage">
        <%!-- At zero, said in words with no meter (UX re-check #7). --%>
        <div class="flex items-baseline justify-between font-mono text-[13px]">
          <span title={Format.exact(@ticket.usage)}>
            {Format.spent(@ticket.usage) || "nothing spent yet"}
          </span>
          <span class="text-ink-3">
            {if Format.spent(@ticket.usage), do: "of", else: "allowance"} {Format.allowance(
              @ticket,
              @workflow
            )}
          </span>
        </div>
        <.allowance
          :if={Format.spent(@ticket.usage)}
          ticket={@ticket}
          workflow={@workflow}
          class="ticket-usage-track"
        />
        <p class="mt-2 font-mono text-[12px] text-ink-2">
          {Format.counted(turns(@jobs), "turn")} · {Format.counted(length(@jobs), "job")}
        </p>
        <p
          :if={@ticket.usage_converted}
          id="ticket-usage-converted"
          class="mt-1 font-mono text-[12px] text-ink-3"
        >
          includes figures converted from dollars
        </p>
      </div>

      <.fact_list id="ticket-facts">
        <:fact label="branch">{@ticket.branch}</:fact>
        <:fact label="base">{String.slice(@ticket.base_commit || "", 0, 12)}</:fact>
        <:fact label="workflow">{String.slice(@ticket.workflow_commit || "", 0, 12)}</:fact>
        <:fact :if={@queue} label="merge queue">{merge_queue_place(@queue)}</:fact>
        <:fact label="step">{@ticket.state} · visit {max(@visits, 1)}</:fact>
        <%!-- Left out until a figure is reported: `5h — · week —` read as broken text. --%>
        <:fact
          :if={
            ForgeWeb.Capacity.percent(@capacity["five_hour"]) ||
              ForgeWeb.Capacity.percent(@capacity["seven_day"])
          }
          label="usage"
        >
          5h {ForgeWeb.Capacity.shown(@capacity["five_hour"])} · week {ForgeWeb.Capacity.shown(
            @capacity["seven_day"]
          )}
        </:fact>
      </.fact_list>

      <%!-- A ticket reads its workflow, prompts and command scripts at its pin for its whole life,
            so a fix that lands on the default branch does not reach it until a person says so
            (`workflow-grammar-v1.md` § Pinning). Said where the pin is, with the way to take it. --%>
      <.pin_drift :if={@drift} drift={@drift} ticket={@ticket} project={@project} />

      <%!-- A merge moved the default branch into conflict with this ticket's changeset: said before
            anybody approves it, with the way down the conflict route — and nothing started until
            it is pressed (`docs/design/ui.md` § The details). --%>
      <div :if={@conflict} id="merge-conflict" class="ticket-notice">
        <p class="text-ink-2">
          {@project.default_branch} no longer merges with this ticket's changeset{since(
            @conflict.cause
          )}:
        </p>
        <ul class="mt-1 flex flex-col gap-0.5 font-mono break-all text-ink-2">
          <li :for={path <- @conflict.paths}>{path}</li>
        </ul>
        <%!-- What happens when the rebase ends `done`, read from the record of approvals now
              (`workflow-grammar-v1.md` § Merging, *What follows the rebase*). --%>
        <p :if={@rebase_outcome} id="rebase-outcome" class="mt-2 text-ink-2">
          {rebase_outcome_sentence(@rebase_outcome)}
        </p>
        <.confirm
          :if={@conflict.send_to}
          id="integrate-ticket"
          label={"Send to #{@conflict.send_to}"}
          act="Send it"
          sentence={
            send_confirm(@conflict.send_to, @workflow, @project.default_branch, @rebase_outcome)
          }
          tone="neutral"
          size="md"
          class="mt-2 items-start"
          phx-click="integrate"
          phx-value-ticket={@ticket.id}
        />
      </div>

      <%!-- The details name what this ticket's jobs proposed and send the decision to the project
            page, where every proposal on the project is in one place. --%>
      <div :if={@proposals != []} id="ticket-proposals">
        <.eyebrow>Proposed here</.eyebrow>
        <ul class="mt-2 flex flex-col gap-1 text-[12.5px] text-ink-2">
          <li :for={p <- @proposals}>{proposal_title(p.version)}</li>
        </ul>
        <p class="mt-1 text-[12.5px] text-ink-3">
          Waiting on you, in <.link
            id="ticket-proposals-link"
            navigate={~p"/projects/#{@project.name}?view=proposals"}
            class="text-link"
          >
            the project's Proposals
          </.link>.
        </p>
      </div>

      <%!-- What the ticket holds, each at its exact version: the changeset among them, which Docs
            leaves to Changes. --%>
      <div id="ticket-artifacts">
        <.eyebrow>What it holds</.eyebrow>
        <div class="mt-2 flex flex-wrap gap-2">
          <.artifact_chip
            :for={entry <- @artifacts}
            entry={entry}
            project={@project.name}
            number={@ticket.number}
          />
        </div>
        <p :if={@artifacts == []} class="text-[12.5px] text-ink-3">
          The first job writes the first document.
        </p>
      </div>

      <div class="flex flex-col gap-2">
        <.link
          :if={@ways != []}
          id="details-ways"
          patch={~p"/tickets/#{@project.name}/#{@ticket.number}?tab=steps"}
          class="ui-btn ui-btn--secondary ui-btn--lg"
        >
          {ways_label(@ways)}
        </.link>
        <.lifecycle ticket={@ticket} />
      </div>
      <%!-- What the details' own buttons were refused, in the panel they were pressed in. --%>
      <Actions.refused
        id="details-refusal"
        refusal={@refusal}
        at={~w(repin integrate cancel-ticket restore-ticket hold-ticket retitle set-milestone)}
      />
    </div>
    """
  end

  defp ways_label([%{label: label}]), do: label <> "…"
  defp ways_label(_several), do: "Ways forward…"

  attr :drift, :map, required: true
  attr :ticket, :map, required: true
  attr :project, :map, required: true

  defp pin_drift(assigns) do
    assigns =
      assign(
        assigns,
        :same_refusal,
        Forge.Update.file_refusal?(get_in(assigns.drift, [:skipped, :code]))
      )

    ~H"""
    <div id="pin-drift" class="ticket-notice">
      <p class="text-ink-2">
        {@project.default_branch} has changed what this ticket runs since it was pinned:
      </p>
      <ul class="mt-1 flex flex-col gap-0.5 font-mono break-all text-ink-2">
        <li :for={path <- @drift.paths}>{path}</li>
      </ul>
      <%!-- An update step that left the pin where it was says why; where the reason is the file's, a
            Re-pin by hand meets the same refusal (`workflow-grammar-v1.md` § Bringing the branch up
            to date). Where it is the step's — no such state there, or not a step — a hand re-pin asks
            only that the ticket's own state exist there, so nothing is promised. --%>
      <p :if={@drift[:skipped]} id="pin-drift-skipped" class="mt-1 break-words text-ink-2">
        The update step did not re-pin it: {String.slice(@drift.skipped.reason, 0, 300)}.{if @same_refusal,
          do: " Re-pinning by hand would meet the same refusal."}
      </p>
      <.repin :if={@ticket.status in Forge.Tickets.Ticket.open_statuses()} {assigns} />
    </div>
    """
  end

  attr :ticket, :map, required: true

  # Cancelling is rare and undoable, so it sits at the foot of the details rather than among the
  # ways forward: `workflow-grammar-v1.md` § Cancelling a ticket.
  defp lifecycle(assigns) do
    ~H"""
    <.button
      :if={@ticket.status in Forge.Tickets.Ticket.open_statuses() and @ticket.held_at == nil}
      id="hold-ticket"
      type="button"
      variant="outline"
      size="lg"
      phx-click="hold-ticket"
      phx-value-ticket={@ticket.id}
    >
      Put on hold
    </.button>
    <.confirm
      :if={@ticket.status in Forge.Tickets.Ticket.open_statuses()}
      id="cancel-ticket"
      label="Cancel ticket"
      act="Cancel it"
      sentence="Cancel this ticket? Its jobs stop and it is hidden everywhere but this page, where Restore brings it back."
      size="lg"
      fill
      phx-click="cancel-ticket"
      phx-value-ticket={@ticket.id}
    />
    <div :if={@ticket.status == :cancelled} class="flex flex-col gap-2">
      <p class="text-[12.5px] text-ink-2">
        Cancelled: hidden everywhere but here. Restoring leaves it stuck in {@ticket.state}.
      </p>
      <button
        type="button"
        id="restore-ticket"
        phx-click="restore-ticket"
        phx-value-ticket={@ticket.id}
        class="ui-btn ui-btn--secondary ui-btn--lg"
      >
        Restore
      </button>
    </div>
    """
  end

  # Re-pinning changes what every later job reads (`workflow-grammar-v1.md` § Pinning): weighty,
  # not destructive, so it is asked in place in the neutral tone.
  defp repin(assigns) do
    assigns = assign(assigns, :head, String.slice(assigns.drift.head, 0, 12))

    ~H"""
    <.confirm
      id="repin-ticket"
      label={"Re-pin at #{@head}"}
      act="Re-pin it"
      sentence={"Re-pin at #{@head}? Every job from now on reads the workflow, its prompts and its command scripts from there."}
      tone="neutral"
      size="md"
      class="mt-2 items-start"
      phx-click="repin"
      phx-value-ticket={@ticket.id}
    />
    """
  end

  # -- a pin that cannot be built ------------------------------------------------------------

  @doc """
  Steps for a ticket whose pin cannot be built (`ui.md` § Steps): said once, in plain words, with
  the way on — neither Re-pin nor Cancel reads the pin (`workflow-grammar-v1.md` § Pinning) — then
  its documents and its history.
  """
  def unreadable(assigns) do
    ~H"""
    <section id="unreadable-pin">
      <.notice tone="danger" title="Cannot be read">
        The workflow this ticket was pinned to can no longer be read, so its steps cannot be
        shown and it cannot move on. Its documents and history are below.
      </.notice>
      <details class="mt-2 text-[12.5px]">
        <summary class="flex min-h-[46px] cursor-pointer items-center text-ink-2">
          What stopped it
        </summary>
        <pre class="overflow-x-auto font-mono whitespace-pre-wrap text-ink-2">{ForgeCore.Error.format(@errors)}</pre>
      </details>
      <div :if={@drift && @ticket.status in Forge.Tickets.Ticket.open_statuses()} id="pin-drift">
        <p class="text-sm/[1.55] text-ink-2">
          {@project.default_branch} has a workflow it can be pinned to instead.
        </p>
        <.repin {assigns} />
      </div>
      <div class="mt-3 flex flex-col gap-2">
        <.lifecycle ticket={@ticket} />
      </div>
      <Actions.refused
        id="unreadable-refusal"
        refusal={@refusal}
        at={~w(repin cancel-ticket restore-ticket unavailable)}
      />
    </section>

    <section id="docs" class="ticket-section">
      <.eyebrow>Documents</.eyebrow>
      <WorkScreen.docs docs={@docs} empty="No job wrote a document on this ticket." />
    </section>

    <section id="history" class="ticket-section">
      <.eyebrow>History</.eyebrow>
      <ol class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
        <li :for={event <- @events} class="flex gap-2">
          <span class="shrink-0 text-ink-3">
            {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
          </span>
          <span class="block min-w-0 truncate">{event.type}</span>
        </li>
      </ol>
    </section>
    """
  end

  # -- helpers -------------------------------------------------------------------------------

  defp admitted(at, now), do: Format.ago_phrase(at, now)

  defp turns(jobs), do: jobs |> Enum.map(& &1.turns) |> Enum.sum()

  # Which merge put the ticket in conflict, when it was one: one that conflicted already names none.
  defp since(%{"ticket" => number}), do: " since ##{number} merged"
  defp since(%{"chat" => _id}), do: " since a conversation merged"
  defp since(_none), do: ""

  # The confirm says what pressing it spends: a job, when the state it sends to runs one — and
  # which of the two follows the rebase, from the record as it is now.
  defp send_confirm(target, workflow, branch, outcome) do
    case Workflow.state(workflow, target) do
      %Workflow.State{chat: true} ->
        "Send this ticket to #{target}? A conversation opens there, waiting for a person." <>
          rebase_after(outcome)

      %Workflow.State{prompt: prompt} when is_binary(prompt) ->
        "Send this ticket to #{target}? A job starts there to merge #{branch} into its branch, " <>
          "and spends a credential." <> rebase_after(outcome)

      _human ->
        "Send this ticket to #{target}? It waits there for a person." <> rebase_after(outcome)
    end
  end

  defp rebase_after(nil), do: ""
  defp rebase_after(outcome), do: " " <> rebase_outcome_sentence(outcome)

  defp rebase_outcome_sentence(:merge),
    do: "Its changeset is approved, so when the rebase ends done it merges on its own."

  defp rebase_outcome_sentence(:ask),
    do:
      "Its changeset is not approved, so when the rebase ends done it comes back for your approval."

  # The details name what this ticket's jobs proposed, by title.
  defp proposal_title(version) do
    case ForgeCore.Proposal.parse(version.content || "") do
      {:ok, proposal} -> proposal.title
      {:error, _errors} -> "(could not be read)"
    end
  end

  @doc """
  How much of its allowance a ticket has spent, as a meter (the details, `6d`, and Changes' Usage):
  a usage line's tones (`ForgeWeb.UI.Navigation.usage_tone/1`) — quiet ink under 80 %, warning
  from 80, danger from 95 — and **never amber** (`docs/design/ui.md` § Colour), because a spent
  allowance waits on nobody. `class` sizes the track.
  """
  attr :ticket, :map, required: true
  attr :workflow, :map, required: true
  attr :class, :string, required: true

  def allowance(assigns) do
    assigns = assign(assigns, :percent, allowance_percent(assigns.ticket, assigns.workflow))

    ~H"""
    <span class={@class} aria-hidden="true"><span
      class={["ui-usage-fill", "ui-usage-fill--#{usage_tone(@percent)}"]}
      style={"width: #{@percent}%"}
    /></span>
    """
  end

  defp allowance_percent(ticket, workflow) do
    cap = workflow.limits.ticket_tokens

    if is_number(cap) and cap > 0 do
      cap = Forge.Spend.ticket_cap(ticket, workflow)

      ticket.usage
      |> Kernel./(cap)
      |> Kernel.*(100)
      |> min(100)
      |> round()
    else
      0
    end
  end
end
