defmodule ForgeWeb.ChatViews do
  @moduledoc """
  What a conversation's page draws inside the frame (`docs/design/ui.md` § A chat, § Talk): its
  details, Talk and its dock, Changes with a conflict's two ways out, and the wide screen's right
  column. `ForgeWeb.ChatLive` holds the data and the events; this only draws.

  Every name that reaches it — a branch, a path, a secret's name, a machine's id — is text, drawn
  escaped by the template.
  """

  use Phoenix.Component
  use ForgeWeb, :verified_routes

  import ForgeWeb.CoreComponents, only: [button: 1]
  import ForgeWeb.Operator.Components, only: [copyable: 1, scroll_pane: 1]
  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1, split_pane: 1]
  import ForgeWeb.UI.Data, only: [eyebrow: 1, fact_list: 1]
  import ForgeWeb.UI.Forms, only: [composer: 1]
  import ForgeWeb.UI.Feedback, only: [error_note: 1, notice: 1]
  import ForgeWeb.UI.Decisions, only: [confirm: 1]

  alias Forge.{Events, Jobs}
  alias ForgeCore.Workflow.Resources
  alias ForgeWeb.{Actions, Diff, FileType, Format, Transcript, WorkScreen}
  alias ForgeWeb.Components.StepAccept
  alias ForgeWeb.Operator.Actions, as: OperatorActions

  # -- the details -----------------------------------------------------------------------------

  @doc """
  The details, dropped from the title (`15e`): what it is about, its facts, the machine it holds,
  the usage lines written out, what it holds by name, and End it with its confirm.

  **The machine is drawn for every member; its link only for its owner**, because the machines'
  pages are their owner's (`docs/design/identity.md` § Workers) and a link a member cannot follow
  is a door drawn on a wall.
  """
  def details(assigns) do
    ~H"""
    <div id="chat-details" class="chat-details">
      <div>
        <p class="chat-details-title">{@title}</p>
        <p class="chat-details-sub">{about(@project, @ticket)}</p>
      </div>

      <.fact_list id="chat-facts">
        <:fact label="project">{@project.name}</:fact>
        <:fact :if={@ticket} label="ticket">#{@ticket.number} {@ticket.title}</:fact>
        <:fact label="harness">
          <span id="chat-harness">{Forge.Jobs.harness_line(@chat, @project)}</span>
        </:fact>
        <:fact label="model">{@model || "the platform's"}</:fact>
        <:fact label="effort">{@effort || "the platform's"}</:fact>
        <:fact label="turns">{@chat.turns}</:fact>
        <:fact label="spent">
          <span title={Format.exact(@chat.usage)}>{Format.windows(@chat.usage) || "—"}</span>
        </:fact>
        <:fact label="branch">{Jobs.chat_branch(@chat)}</:fact>
        <:fact label="machine">
          <.machine machine={@machine} viewer={@viewer} />
        </:fact>
        <%!-- The usage lines written out, as facts on the facts' edge; with nothing reported, one
              row in the title menu's words rather than `5h —` and `week —` (UX re-check #7). --%>
        <:fact :if={not reported?(@capacity)} label="usage">no figures yet</:fact>
        <:fact :if={reported?(@capacity)} label="5h">
          <.usage_window window={@capacity["five_hour"]} now={@now} />
        </:fact>
        <:fact :if={reported?(@capacity)} label="week">
          <.usage_window window={@capacity["seven_day"]} now={@now} />
        </:fact>
      </.fact_list>

      <%!-- Only when memory was the trouble (`docs/design/capacity.md` § Memory, which a job
            holds rather than spends). --%>
      <p :if={@memory} id="chat-memory" class="text-sm/[1.5] text-warning">
        {Forge.Jobs.Memory.words(@memory)}
      </p>
      <%!-- What it was opened with, less what has gone since: the names, never a value. --%>
      <p
        :if={@chat.secret_names -- @secrets_gone != []}
        id="chat-secrets"
        class="font-mono text-[12.5px] text-ink-2 [overflow-wrap:anywhere]"
      >
        holds {Enum.join(@chat.secret_names -- @secrets_gone, ", ")}
      </p>
      <p
        :for={name <- @secrets_gone}
        class="chat-secret-gone text-sm/[1.5] text-warning [overflow-wrap:anywhere]"
      >
        {name} was deleted and this conversation no longer holds it
      </p>

      <%!-- End refused: drawn where it was pressed, which outlives the button it replaces. --%>
      <.error_note :if={match?({:details, _}, @chat_error)} id="chat-ending-error">
        {elem(@chat_error, 1)}
      </.error_note>

      <section :if={@live} id="chat-ending">
        <.confirm
          id="chat-end"
          label="End it"
          act="End it"
          sentence={ForgeWeb.Conversations.ending_confirm()}
          size="md"
          fill
          phx-click="close"
        />
        <p id="ending-copy" class="mt-2 text-[12.5px]/[1.5] text-ink-2">
          It holds a worker until it ends or goes idle. If you end it, {ForgeWeb.Conversations.ending_rule()}; going idle does not.
        </p>
      </section>
    </div>
    """
  end

  attr :machine, :map, default: nil
  attr :viewer, :map, required: true

  @doc "The machine a conversation holds, in one line; linked only for its owner."
  def machine(assigns) do
    ~H"""
    <span :if={is_nil(@machine)} id="chat-machine" class="text-ink-3">none held</span>
    <span :if={@machine} id="chat-machine"><.link
      :if={@machine.owner_id == @viewer.id}
      id="chat-machine-link"
      navigate={~p"/workers/#{@machine.id}"}
      class="text-link"
    >{machine_name(@machine)}</.link><span :if={@machine.owner_id != @viewer.id}>{machine_name(@machine)}</span>{machine_shape(
      @machine
    )}</span>
    """
  end

  # The provider's own name for it when it has one, else the provider: what a person would find
  # it by in their provider's console.
  defp machine_name(%{provider_id: id}) when is_binary(id) and id != "", do: id
  defp machine_name(%{provider: provider}) when is_binary(provider), do: provider
  defp machine_name(_machine), do: "a machine"

  defp machine_shape(machine) do
    [
      (is_integer(machine.memory) and machine.memory > 0) && memory(machine.memory),
      is_integer(machine.cores) &&
        "#{machine.cores} #{if machine.cores == 1, do: "core", else: "cores"}"
    ]
    |> Enum.filter(& &1)
    |> Enum.map_join("", &(" · " <> &1))
  end

  # Whole gibibytes as `8 GiB`, the way a machine is sized; anything else to one decimal.
  @gib 1024 * 1024 * 1024
  defp memory(bytes) when rem(bytes, @gib) == 0, do: "#{div(bytes, @gib)} GiB"
  defp memory(bytes), do: Resources.gib(bytes)

  attr :window, :map, default: nil
  attr :now, :any, required: true

  defp usage_window(assigns) do
    ~H"""
    {if ForgeWeb.Capacity.percent(@window),
      do: ForgeWeb.Capacity.shown(@window),
      else: "no figure yet"}<span
      :if={@window && @window[:soonest]}
      class="text-ink-3"
    > · resets {Format.until_phrase(@window.soonest, @now)}</span>
    """
  end

  defp reported?(capacity),
    do: Enum.any?(~w(five_hour seven_day), &ForgeWeb.Capacity.percent(capacity[&1]))

  defp about(project, nil), do: "A conversation about #{project.name}, not tied to a ticket."
  defp about(_project, _ticket), do: "About this ticket, from its branch as it stood."

  # -- Talk ------------------------------------------------------------------------------------

  @doc """
  The transcript, pinned to the bottom; on a stopped conversation dimmed, since nothing more will
  be said in it until it is reopened (`15d`).
  """
  def talk(assigns) do
    ~H"""
    <.scroll_pane id="messages-pane" height={nil} class="py-4">
      <ol
        class={["chat-messages", not @live && "chat-messages--stopped"]}
        id="messages"
        data-scroll-items
      >
        <Transcript.transcript
          messages={@messages}
          live={@live}
          now={@at}
          refs={@refs}
          banded={@responding && @plan != []}
        />
      </ol>

      <p :if={@messages == []} class="text-sm text-ink-3">Nothing said yet.</p>

      <%!-- A conversation that has not started yet says why, where the reply will appear: the
            scheduler's sentence, the latest since it last started (docs/design/ui.md § A job
            waiting for a machine). A chat sticks nothing, so this and — for a chat step — the
            ticket's own page are the only surfaces that say a template is missing. --%>
      <p :if={@waiting} id="chat-waiting" class="mt-4 text-sm/[1.55] text-ink-2">
        {Events.summary(@waiting)}
      </p>
    </.scroll_pane>
    """
  end

  @doc """
  What sits under the content (`15a`), from the top down: the last reply's question card in the
  split pane, the plan band, the now line with Stop, the step's status, then the composer — or,
  on a stopped conversation, the reopen sentence and Reopen in its place (`15d`).
  """
  def dock(assigns) do
    ~H"""
    <div class="chat-dock">
      <%!-- A send or a reopen refused: under the conversation it belongs to, above what to do. --%>
      <.error_note :if={match?({:dock, _}, @chat_error)} id="chat-error">
        {elem(@chat_error, 1)}
      </.error_note>
      <%!-- A card's Send refused whose card has gone — the conversation stopped, or the questions
            were answered elsewhere: drawn where the card stood. --%>
      <OperatorActions.refused
        :if={not (@questions != [] && @live && @tab == "talk")}
        id="questions-refusal"
        refusal={@refusal}
        at={[:questions]}
      />
      <%!-- Gone when the conversation is, for the same reason the box is: the card's Send is a
            send button, and one offered on a dead conversation takes a tap and loses it. What it
            asked stays legible in the transcript. --%>
      <section :if={@questions != [] && @live && @tab == "talk"} id="answer-rows">
        <.split_pane id="chat-pane">
          <.question_form
            id={"chat-#{@chat_id}-#{@reply}"}
            questions={@questions}
            forms={@forms}
            refusal={@refusal}
            submit="chat:questions:send"
            hidden={[{"chat", @chat_id}, {"reply", @reply}]}
          />
        </.split_pane>
      </section>

      <.plan_band :if={@responding && @plan != []} plan={@plan} />

      <%!-- Static text: ui.md § Motion and structure says nothing pulses, and a conversation you
            are waiting on is exactly where a decorative animation would be most tempting and
            least honest. --%>
      <div :if={@responding} id="now-line" class="chat-now">
        <span class="chat-now-words">{Actions.now_words(@now) || "…"}</span>
        <.button type="button" size="sm" phx-click="stop">Stop</.button>
      </div>

      <StepAccept.status :if={@step} step={@step} />

      <%!-- While the agent is responding a typed message interrupts it, and the button says so:
            *Interrupt and send* names what it costs — the turn already spent on is spent
            (`docs/design/conversations.md` § Turns). With nothing typed it is still Send. --%>
      <form :if={@live} id="say" phx-change="draft" phx-submit="send" class="chat-say">
        <%!-- Drawn with the button that says so, from the same assigns, so what is sent is what
              the button named. --%>
        <input :if={interrupts?(@responding, @draft)} type="hidden" name="interrupt" value="true" />
        <.composer
          id="draft"
          name="text"
          value={@draft}
          placeholder="Reply to the agent"
          interrupt={interrupts?(@responding, @draft)}
          phx-debounce="200"
        />
        <%!-- The gesture that sends, named only where it is true: a fine pointer's Enter. On a
              coarse one Enter is a new line and only the button sends (§ Talk), and the query is
              the same one the field's hook reads, written as CSS. --%>
        <p class="chat-hint pointer-coarse:hidden" data-hint>
          Enter sends · shift-enter for a new line
        </p>
      </form>

      <section :if={not @live and not step_over?(@step)} id="reopen" class="chat-reopen">
        <p id="reopen-copy" class="text-sm/[1.55] text-ink-2">
          This conversation has stopped. Reopening starts a new process on a new machine: it is
          given everything said here to read, and answers the next thing you say.
          <%= if @branch_exists do %>
            It works on its branch as it stands.
          <% else %>
            Its branch is gone — a merge deletes it, and so does ending — so it starts one again
            from <span class="font-mono text-[12.5px]">{@base_branch}</span> as it stands now.
          <% end %>
        </p>
        <.button type="button" variant="primary" fill phx-click="reopen">Reopen</.button>
      </section>
    </div>
    """
  end

  @doc "Whether sending now interrupts the agent: it is responding and something is typed."
  @spec interrupts?(boolean(), String.t() | nil) :: boolean()
  def interrupts?(responding, draft), do: responding and String.trim(draft || "") != ""

  defp step_over?(%{over: over}), do: over != nil
  defp step_over?(nil), do: false

  attr :plan, :list, required: true

  # The agent's own plan, folded to its current item with a track of how far it is; it opens to
  # the whole checklist (`15a`).
  defp plan_band(assigns) do
    assigns =
      assign(assigns,
        done: Enum.count(assigns.plan, &(&1["status"] == "completed")),
        current: Actions.current_todo(assigns.plan)
      )

    ~H"""
    <details id="plan" class="chat-plan" phx-mounted={Actions.keep_open()}>
      <summary class="chat-plan-summary">
        <span class="chat-plan-count">{@done}/{length(@plan)}</span>
        <span class="chat-plan-now">{(@current && Actions.todo_text(@current)) || "done"}</span>
        <span class="chat-plan-fold" aria-hidden="true">▾</span>
      </summary>
      <div class="chat-plan-track" aria-hidden="true">
        <span :for={todo <- @plan} data-status={todo["status"]} />
      </div>
      <div class="chat-plan-list"><Actions.checklist todos={@plan} /></div>
    </details>
    """
  end

  # -- Changes ---------------------------------------------------------------------------------

  @doc """
  What the branch holds against the default branch, and when it does not merge cleanly the
  conflict with its two ways out as rows (`15c`): asking the agent to rebase fills the composer,
  so what is sent can still be edited; taking it by hand is the fetch command to copy.
  """
  def changes(assigns) do
    ~H"""
    <section :if={@conflict} id="chat-conflict" class="chat-conflict">
      <.notice tone="danger" title="Does not merge cleanly">
        {@project.default_branch} moved since this branch started. These files changed on both
        sides:
        <span :for={path <- @conflict} class="mt-1 block font-mono text-[12.5px] break-all">
          {path}
        </span>
      </.notice>

      <.ways_out live={@live} fetch={@fetch} />

      <p class="text-sm text-ink-3">The files and commits are below, unchanged.</p>
    </section>

    <section class={@conflict && "mt-8"}>
      <.eyebrow>What it changed</.eyebrow>
      <div class="mt-3">
        <Diff.file_table :if={@diff} diff={@diff} ask="ask" />
        <p :if={!@diff} class="text-sm/[1.55] text-ink-2">
          There is no branch to compare: a merge deletes it, and so does ending.
        </p>
      </div>
    </section>

    <WorkScreen.commits commits={@commits} now={@at} />

    <%!-- Merging is the decision row's, on every view (`docs/design/ui.md` § The decision row). --%>
    <p :if={@diff && @merged} id="chat-merged" class="mt-8 text-sm/[1.55] text-ink-2">
      Already on {@project.default_branch}.
    </p>
    """
  end

  attr :live, :boolean, required: true
  attr :fetch, :string, required: true
  attr :prefix, :string, default: "", doc: "for the ids, where Changes and the aside both draw it"

  # A conflict's two ways out (`15c`): asking the agent to rebase, which fills the composer, and
  # the fetch command to take it by hand.
  defp ways_out(assigns) do
    ~H"""
    <button
      :if={@live}
      type="button"
      id={"#{@prefix}ask-rebase"}
      phx-click="rebase:ask"
      class="chat-way"
    >
      <span class="chat-way-text">
        <span class="chat-way-title">Ask it to rebase</span>
        <span class="chat-way-detail">Puts the request in the composer, with the paths.</span>
      </span>
      <span aria-hidden="true">›</span>
    </button>

    <div id={"#{@prefix}take-by-hand"} class="chat-way chat-way--static">
      <span class="chat-way-text">
        <span class="chat-way-title">Take the change by hand</span>
        <span class="chat-way-detail">Fetch the branch, merge it yourself, and push.</span>
        <.copyable id={"#{@prefix}chat-fetch"} value={@fetch} />
      </span>
    </div>
    """
  end

  @doc "What *Ask it to rebase* puts in the composer: the request, with the paths."
  @spec rebase_request(String.t(), [String.t()]) :: String.t()
  def rebase_request(branch, paths) do
    "Rebase onto #{branch}: " <>
      Enum.map_join(paths, ", ", &Path.basename/1) <>
      " conflict. Resolve them, keep both sides' intent, and say what you chose."
  end

  # -- the wide screen's right column ----------------------------------------------------------

  @doc """
  A conversation's right column on a wide screen (`15f`): what the branch holds, the commit its
  merge would make, Merge, the facts and End it — so Changes stops being a view. Drawn at every
  width and shown only from 1440px, by CSS (`areas/chat.css`), which also hides the Changes tab and
  the merge row there.
  """
  def aside(assigns) do
    ~H"""
    <div id="chat-aside-branch" class="chat-aside">
      <section>
        <div class="flex items-baseline justify-between gap-3">
          <.eyebrow>What it changed</.eyebrow>
          <Diff.stat diff={@diff} />
        </div>
        <Diff.file_table :if={@diff} diff={@diff} id="aside-files" />
        <p :if={!@diff} class="mt-2 text-sm/[1.55] text-ink-2">
          There is no branch to compare: a merge deletes it, and so does ending.
        </p>
        <p :if={@diff} class="mt-2 font-mono text-[12px] text-ink-3">
          {length(@commits)} {if length(@commits) == 1, do: "commit", else: "commits"} on {Jobs.chat_branch(
            @chat
          )} · against {@project.default_branch}
        </p>
      </section>

      <section :if={@merge} id="aside-merge" class="flex flex-col gap-3">
        <WorkScreen.commit_message version={@merge.commit_message} id="aside-commit-message" />
        <%!-- A conflict puts its two ways out where Merge would be: a disabled Merge and a link to
              them elsewhere was a button for an act that would be refused (UX pass, B7). --%>
        <div :if={@merge.conflict} id="aside-conflict" class="flex flex-col gap-3">
          <p class="text-sm/[1.55] text-danger">
            It does not merge cleanly: {Enum.join(@merge.conflict, ", ")}.
          </p>
          <.ways_out live={@live} fetch={@fetch} prefix="aside-" />
        </div>
        <.error_note :if={@error} id="aside-merge-error">
          {@error}
        </.error_note>
        <form
          :if={@merge.commit_message && !@merge.conflict}
          id="aside-merge-form"
          phx-submit="decision:merge"
        >
          <.button
            type="submit"
            variant="neutral"
            size="md"
            class="w-full"
            phx-disable-with="Merging…"
          >
            Merge into {@project.default_branch}
          </.button>
        </form>
      </section>

      <.fact_list id="aside-facts" dense>
        <:fact label="model">{@model || "the platform's"}</:fact>
        <:fact label="effort">{@effort || "the platform's"}</:fact>
        <:fact label="turns">{@chat.turns}</:fact>
        <:fact label="spent">
          <span title={Format.exact(@chat.usage)}>{Format.windows(@chat.usage) || "—"}</span>
        </:fact>
      </.fact_list>
    </div>
    """
  end

  @doc """
  A chat step's right column on a wide screen (`16i`): the step's document beside the
  conversation, rendered, so it is read while it is talked about.
  """
  def step_aside(assigns) do
    ~H"""
    <article id="aside-document" class="chat-aside">
      <header class="flex items-baseline justify-between gap-3 font-mono text-[12.5px]">
        <span class="min-w-0 truncate">{@doc.name} v{@doc.latest.version}</span>
        <.link href={@doc.latest.href} class="shrink-0 text-link">Open ›</.link>
      </header>
      <FileType.document_body body={@doc.latest.body} />
    </article>
    """
  end

  @doc """
  The document a step's wide screen reads beside the conversation: the step's own with the newest
  version that this conversation wrote and that has a body to render, or nil.
  """
  @spec step_doc(map() | nil, [map()]) :: map() | nil
  def step_doc(nil, _docs), do: nil

  def step_doc(step, docs) do
    names = for %{own: true, version: version, name: name} <- step.documents, version, do: name
    Enum.find(docs, &(&1.name in names and &1.latest.body != nil))
  end
end
