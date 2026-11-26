defmodule ForgeWeb.Components.TakeoverBand do
  @moduledoc """
  What a **taken-over** ticket draws where a hold's band is (`docs/design/ui.md` § The ticket,
  `docs/design/outside-work.md`): who took it over and how long ago, the commits pushed to its
  branch since — *recorded when it is handed back* — a line to copy that fetches the branch, **Hand
  back** with its step picker and note, and **Stop now** while a run of its state is going. Neutral,
  as a hold's band is: nothing waits on you.

  **Nothing here carries a token.** The fetch line is the project's git address and the branch,
  and a person's own token is the credential they already hold. The note is drawn as text and
  never as markup; its limit is `Forge.Tickets.Takeover.note_limit/0`, enforced by
  `Forge.Operator` and never by cutting what was typed.

  The two reads (`facts/2`, `steps/2`) are made on a load, never in a render.
  """

  use ForgeWeb, :html

  import ForgeWeb.Operator.Components, only: [copyable: 1]

  alias Forge.{Engine, Git, Jobs, Projects, Repo}
  alias Forge.Tickets.{Takeover, Ticket}
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias ForgeWeb.Operator.{Actions, Drafts}

  @doc """
  The open take-over of the ticket as the band draws it, or nil for a ticket that is not taken
  over: `by` (an event's actor map, nil when the person or token is gone), `at`, `via`, `state`,
  `pushed` (how many commits were pushed to the branch since — the ones a hand-back would record,
  as `Forge.Engine.hand_back/3` counts them) and `fetch`, the line to copy.
  """
  @spec facts(Ticket.t(), Forge.Projects.Project.t()) :: map() | nil
  def facts(%Ticket{takeover_id: nil}, _project), do: nil

  def facts(%Ticket{takeover_id: id} = ticket, project) do
    case Repo.get(Takeover, id) do
      nil ->
        nil

      takeover ->
        takeover = Repo.preload(takeover, :token)
        who = Takeover.taker(takeover)

        %{
          by: who && Forge.Events.encode_actor(who),
          at: takeover.taken_at,
          via: takeover.via,
          state: takeover.state,
          pushed: pushed(ticket, project, takeover),
          fetch: fetch_line(project, ticket)
        }
    end
  end

  # `git fetch <address> ticket/<n>`: the address is the project's and never carries a credential.
  defp fetch_line(project, ticket), do: "git fetch #{Git.Url.for(project)} #{ticket.branch}"

  defp pushed(ticket, project, takeover) do
    repo = Projects.repo_path(project)

    case Git.resolve(repo, "refs/heads/" <> ticket.branch) do
      {:ok, head} ->
        pushed = Engine.pushed_commits(repo, takeover, Engine.jobs_changeset(ticket), head)
        length(pushed["list"]) + pushed["more"]

      _unreadable ->
        0
    end
  end

  @doc """
  Every state of the ticket's pinned workflow a hand-back may continue from, in the workflow's own
  order: `name`, `kind` — `:here` for the state it rests in (a release, or a run again of a stuck
  one), `:edge` for a state a declared transition from it reaches, `:jump` for any other — and
  `missing`, the documents that state's job needs and has no version of, which refuse the hand-back
  (`Forge.Jobs.missing_inputs/3`, the same read a jump's refusal uses).
  """
  @spec steps(Ticket.t(), Workflow.t()) :: [map()]
  def steps(%Ticket{} = ticket, %Workflow{} = workflow) do
    jumps = MapSet.new(Engine.jumps(ticket, workflow))

    for name <- Workflow.state_names(workflow) do
      cond do
        name == ticket.state ->
          %{name: name, kind: :here, missing: []}

        MapSet.member?(jumps, name) ->
          %{name: name, kind: :jump, missing: Jobs.missing_inputs(ticket, workflow, name)}

        true ->
          %{name: name, kind: :edge, missing: Jobs.missing_inputs(ticket, workflow, name)}
      end
    end
  end

  @doc """
  Who took it over, as the page says it: the viewer as *you*, a token as `API · <name>`, another
  member by the address Activity shows (`addresses`, `Forge.Accounts.addresses/1`), else *a member*.
  """
  @spec who(map() | nil, String.t(), %{String.t() => String.t()}) :: String.t()
  def who(%{"kind" => "user", "id" => me}, me, _addresses), do: "you"
  def who(%{"kind" => "user", "id" => id}, _me, addresses), do: Map.get(addresses, id, "a member")
  def who(%{"kind" => "api"} = actor, _me, _addresses), do: Format.author(actor) || "a token"
  def who(_gone, _me, _addresses), do: "someone"

  @doc """
  The band of a taken-over ticket. `drafts` holds the hand-back form's pick and note across a
  reconnect (`docs/design/ui.md` § A reconnect is not a reload).
  """
  attr :ticket, :map, required: true
  attr :takeover, :map, required: true
  attr :steps, :list, required: true
  attr :stoppable, :boolean, required: true
  attr :refusal, :map, default: nil
  attr :drafts, :map, required: true
  attr :me, :string, required: true
  attr :addresses, :map, required: true
  attr :now, :any, required: true

  def band(assigns) do
    assigns =
      assign(assigns,
        note: Drafts.field(assigns.drafts, "hand-back", "note"),
        pick: Drafts.field(assigns.drafts, "hand-back", "to", assigns.ticket.state),
        limit: Takeover.note_limit()
      )

    ~H"""
    <div id="hold-band" class="ticket-hold ticket-takeover">
      <div class="ticket-hold-line">
        <span id="takeover-word" class="ticket-hold-word">
          Taken over by {who(@takeover.by, @me, @addresses)} · {Format.ago_phrase(@takeover.at, @now)}
        </span>
        <span id="takeover-pushed" class="ticket-hold-waits">
          {pushed_words(@takeover.pushed)}
        </span>
      </div>
      <div class="ticket-hold-actions">
        <details id="hand-back-panel" class="ticket-handback" open={@note != "" or @refusal != nil}>
          <summary id="hand-back-open" class="ui-btn ui-btn--outline ui-btn--md">Hand back</summary>
          <form
            id="hand-back-form"
            phx-change="draft:change"
            phx-submit="hand-back"
            class="ticket-handback-form"
          >
            <input type="hidden" name="draft" value="hand-back" />
            <input type="hidden" name="ticket" value={@ticket.id} />
            <fieldset class="ticket-handback-steps">
              <legend class="ui-field-label">Continue from</legend>
              <label
                :for={step <- @steps}
                class="ticket-handback-step"
                id={"hand-back-step-#{step.name}"}
              >
                <input type="radio" name="to" value={step.name} checked={step.name == @pick} />
                <span class="ticket-handback-name">{step.name}</span>
                <span class="ticket-handback-kind">{kind_word(step.kind)}</span>
                <span :if={step.missing != []} class="ticket-handback-missing">
                  needs {Enum.join(step.missing, ", ")}
                </span>
              </label>
            </fieldset>
            <label class="ticket-retitle-field">
              <span class="ui-field-label">Note, optional · at most {@limit} characters</span>
              <textarea id="hand-back-note" name="note" rows="3" class="ui-field-input">{@note}</textarea>
            </label>
            <.button id="hand-back-send" type="submit" variant="primary" size="md">
              Hand back
            </.button>
          </form>
        </details>
        <.confirm
          :if={@stoppable}
          id="stop-now"
          label="Stop now"
          act="Stop it"
          sentence="Stop the run now? What it spent is counted, and the state runs again when you hand it back."
          tone="neutral"
          size="md"
          phx-click="stop-now"
          phx-value-ticket={@ticket.id}
        />
      </div>
      <div id="takeover-fetch-line" class="ticket-takeover-fetch">
        <.copyable id="takeover-fetch" value={@takeover.fetch} />
      </div>
      <Actions.refused id="hold-refusal" refusal={@refusal} at={~w(hand-back stop-now)} />
    </div>
    """
  end

  @doc """
  The read the stuck item of a **moved branch** is drawn from (`docs/design/outside-work.md` §
  Keeping the job's work), or nil: the stop's facts as `Forge.Engine.branch_moved_stop/1` has them
  and `fetch`, the line that fetches the job's kept work. Made on a load, never in a render.
  """
  @spec moved(Ticket.t(), Forge.Projects.Project.t()) :: map() | nil
  def moved(%Ticket{} = ticket, project) do
    case Engine.branch_moved_stop(ticket) do
      nil ->
        nil

      stop ->
        pushers = stop["pushers"] || []

        %{
          job_id: stop["job_id"],
          kept?: is_binary(stop["kept"]),
          arrived: stop["arrived"] || [],
          pushers: pushers,
          addresses:
            Forge.Accounts.addresses(for(%{"kind" => "user", "id" => id} <- pushers, do: id)),
          fetch: "git fetch #{Git.Url.for(project)} refs/forge/kept/#{stop["job_id"]}"
        }
    end
  end

  @doc """
  What a ticket stopped because its branch moved during a job says: the commits that arrived and who
  pushed them, where the job's work is kept (a line to copy) and the three ways out — **Keep the
  job's work**, here; **Take over** (the details'); **Run again** (the ways forward below). A
  refusal of keeping — the two clash in some paths, say — is drawn here and leaves all three.
  """
  attr :moved, :map, required: true
  attr :ticket, :map, required: true
  attr :refusal, :map, default: nil
  attr :me, :string, required: true
  attr :addresses, :map, required: true

  def moved_branch(assigns) do
    ~H"""
    <div id="moved-branch" class="ticket-moved">
      <p id="moved-arrived" class="text-sm/[1.55]">
        {arrived_words(length(@moved.arrived))}
        <span :if={@moved.pushers != []}>
          Pushed by {Enum.map_join(
            @moved.pushers,
            ", ",
            &who(&1, @me, Map.merge(@addresses, @moved.addresses))
          )}.
        </span>
      </p>
      <ul :if={@moved.arrived != []} id="moved-commits" class="ticket-moved-commits">
        <li :for={commit <- @moved.arrived} class="ticket-moved-commit">
          <span class="font-mono text-ink-3">{String.slice(commit["sha"], 0, 8)}</span>
          <span class="min-w-0 [overflow-wrap:anywhere]">{commit["subject"]}</span>
        </li>
      </ul>
      <div :if={@moved.kept?} id="moved-kept" class="flex flex-col gap-2">
        <p class="text-sm/[1.55] text-ink-2">
          The job's work is kept aside, not on the branch. Fetch it to look:
        </p>
        <.copyable id="moved-fetch" value={@moved.fetch} />
      </div>
      <p :if={!@moved.kept?} id="moved-nothing-kept" class="text-sm/[1.55] text-ink-2">
        The worker could not keep the job's work, so only Run again and Take over remain.
      </p>
      <div class="ticket-moved-actions">
        <.button
          :if={@moved.kept?}
          id="keep-work"
          type="button"
          variant="outline"
          size="md"
          phx-click="keep-work"
          phx-value-ticket={@ticket.id}
          phx-value-job={@moved.job_id}
        >
          Keep the job's work
        </.button>
        <.button
          id="moved-take-over"
          type="button"
          variant="outline"
          size="md"
          phx-click="take-over"
          phx-value-ticket={@ticket.id}
        >
          Take it over
        </.button>
      </div>
      <p class="text-[12.5px] text-ink-2">
        Run again is in the ways forward below. It runs the step on the new commits
        and leaves the kept work unused.
      </p>
      <Actions.refused id="keep-work-refusal" refusal={@refusal} at={~w(keep-work)} />
    </div>
    """
  end

  defp arrived_words(0), do: "The branch moved while the job ran."
  defp arrived_words(1), do: "1 commit arrived on the branch while the job ran."
  defp arrived_words(n), do: "#{n} commits arrived on the branch while the job ran."

  defp kind_word(:here), do: "where it rests"
  defp kind_word(:edge), do: "transition"
  defp kind_word(:jump), do: "jump"

  defp pushed_words(0), do: "nothing pushed to the branch since"

  defp pushed_words(1),
    do: "1 commit pushed to the branch since; recorded when it is handed back"

  defp pushed_words(n),
    do: "#{n} commits pushed to the branch since; recorded when it is handed back"

  @doc """
  What the details draw beside *Put on hold*: **Take over**. With a run going it asks what to do
  with it, *Stop it now* or *Let it finish*, neither preselected — the page presses nothing for the
  person (`docs/design/outside-work.md`).
  """
  attr :ticket, :map, required: true
  attr :running, :boolean, required: true
  attr :refusal, :map, default: nil

  def take_over(assigns) do
    ~H"""
    <div
      :if={@ticket.status in Forge.Tickets.Ticket.open_statuses() and @ticket.takeover_id == nil}
      id="take-over"
      class="flex flex-col gap-2"
    >
      <.button
        :if={not @running}
        id="take-over-ticket"
        type="button"
        variant="outline"
        size="lg"
        phx-click="take-over"
        phx-value-ticket={@ticket.id}
      >
        Take over
      </.button>
      <div :if={@running} id="take-over-choice" class="flex flex-col gap-2">
        <p class="text-[12.5px] text-ink-2">
          A run of {@ticket.state} is going. Take over by stopping it now, or let it finish first.
        </p>
        <.button
          id="take-over-stop"
          type="button"
          variant="outline"
          size="lg"
          phx-click="take-over"
          phx-value-ticket={@ticket.id}
          phx-value-running="stop"
        >
          Take over, stop it now
        </.button>
        <.button
          id="take-over-finish"
          type="button"
          variant="outline"
          size="lg"
          phx-click="take-over"
          phx-value-ticket={@ticket.id}
          phx-value-running="finish"
        >
          Take over, let it finish
        </.button>
      </div>
      <Actions.refused id="take-over-refusal" refusal={@refusal} at={~w(take-over)} />
    </div>
    """
  end
end
