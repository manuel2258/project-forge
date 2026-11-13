defmodule ForgeWeb.ProposalsView do
  @moduledoc """
  A project's proposals as its Proposals view draws them (`docs/design/ui.md` § Proposals,
  `7e`, `8a`–`8g`): **grouped by the job that wrote them**, newest batch first — a chat that ended
  with three ideas, a ticket's job that split it into four — the reader one proposal at a time,
  selection with a group's box, and the history of what became of them.

  `groups/3` makes the groups from `Forge.Proposals.open/1` and two lookups the page reads once;
  nothing here reads the database. The decisions themselves are `Forge.Operator`'s.

  The type a proposal suggests is preselected in the reader only if it is one of the project's
  ordinary types now; a suggestion that is not is said, and nothing is preselected
  (`docs/design/ticket-types.md` § Proposals). A type whose workflow does not parse is offered
  marked as such, as on the ticket form.
  """

  use ForgeWeb, :html

  alias ForgeWeb.{Format, Indicators, Markdown, Topology}
  alias ForgeWeb.Operator.Drafts

  @typedoc "One open proposal, flattened for drawing."
  @type item :: %{
          version_id: String.t(),
          file: String.t(),
          title: String.t() | nil,
          body: String.t(),
          readable: boolean(),
          suggested: String.t() | nil,
          at: DateTime.t()
        }

  @typedoc "The proposals one job wrote, and where it came from."
  @type group :: %{
          job_id: String.t(),
          chat: boolean(),
          source: String.t(),
          at: DateTime.t(),
          items: [item()]
        }

  @doc """
  The open proposals as groups, one per job that wrote them, the group with the newest proposal
  first and each group's proposals in the order they were written. `tickets` is every ticket of
  the project by id (a cancelled one's too: its proposals are still its), `openings` what each
  chat was opened with.
  """
  @spec groups([map()], map(), map()) :: [group()]
  def groups(found, tickets, openings) do
    found
    |> Enum.group_by(& &1.job.id)
    |> Enum.map(fn {job_id, [first | _] = all} ->
      items = Enum.map(all, &item/1)

      %{
        job_id: job_id,
        chat: first.job.kind == :chat,
        source: source(first.job, tickets, openings),
        at: items |> Enum.map(& &1.at) |> Enum.max(DateTime),
        items: items
      }
    end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  defp item(found) do
    {title, body, readable, suggested} =
      case ForgeCore.Proposal.parse(found.version.content || "") do
        {:ok, proposal} -> {proposal.title, proposal.body, true, proposal.ticket_type}
        {:error, errors} -> {nil, ForgeCore.Error.format(errors), false, nil}
      end

    %{
      version_id: found.version.id,
      file: found.artifact.name,
      title: title,
      body: body,
      readable: readable,
      suggested: suggested,
      at: found.version.inserted_at
    }
  end

  @doc "Where a job's proposals came from, in words: the chat by its opening, or the ticket."
  @spec source(map(), map(), map()) :: String.t()
  def source(%{kind: :chat} = job, tickets, openings) do
    case {Map.get(openings, job.id), job.ticket_id && tickets[job.ticket_id]} do
      {nil, nil} -> "a conversation"
      {nil, ticket} -> "a conversation on ##{ticket.number}"
      {opening, _ticket} -> "the chat “#{String.slice(opening, 0, 80)}”"
    end
  end

  def source(job, tickets, _openings) do
    case tickets[job.ticket_id] do
      nil -> "a job"
      ticket -> "ticket ##{ticket.number} · #{ticket.title}"
    end
  end

  @doc "Every open proposal's version id, in the order the list draws them."
  @spec order([group()]) :: [String.t()]
  def order(groups), do: for(group <- groups, item <- group.items, do: item.version_id)

  # -- the list ---------------------------------------------------------------------------

  @doc """
  The groups (`8a`), each named by its source over its proposals on a rail. A row is the title and
  the first two lines of the body and opens the reader; while selecting (`8c`, `8f`) a row is a
  checkbox instead — a link never encloses a control — and a group's header gains a box that
  selects or clears the whole group, a dash when only some are picked.
  """
  attr :groups, :list, required: true
  attr :project, :string, required: true
  attr :selecting, :boolean, default: false
  attr :selected, :any, required: true, doc: "a MapSet of version ids"
  attr :reading, :string, default: nil
  attr :now, :any, required: true

  def list(assigns) do
    ~H"""
    <form id="proposal-select" phx-change="proposals:select" class="proposal-groups">
      <section
        :for={group <- @groups}
        id={"source-#{group.job_id}"}
        class="proposal-group"
      >
        <div class="proposal-group-head">
          <button
            :if={@selecting}
            type="button"
            id={"select-group-#{group.job_id}"}
            class="proposal-box"
            role="checkbox"
            aria-checked={group_state(group, @selected)}
            phx-click="proposals:group"
            phx-value-job={group.job_id}
            aria-label="Select every proposal from this source"
          >
            {box_mark(group_state(group, @selected))}
          </button>
          <span class="proposal-group-source">From {group.source}</span>
          <span class="proposal-group-meta">
            {length(group.items)} · {Format.ago(group.at, @now)}
          </span>
        </div>
        <ol class="proposal-rail">
          <li :for={item <- group.items} id={"proposal-#{item.version_id}"}>
            <label :if={@selecting} class="proposal-row proposal-row--select">
              <input
                type="checkbox"
                name="ids[]"
                value={item.version_id}
                checked={MapSet.member?(@selected, item.version_id)}
                class="proposal-check"
              />
              <.row_text item={item} />
            </label>
            <.link
              :if={not @selecting}
              patch={~p"/projects/#{@project}?#{[view: "proposals", read: item.version_id]}"}
              class={["proposal-row", @reading == item.version_id && "proposal-row--reading"]}
            >
              <.row_text item={item} />
            </.link>
          </li>
        </ol>
      </section>
      <%!-- Always one field, so a form whose every box is cleared still sends a change. --%>
      <input type="hidden" name="ids[]" value="" />
    </form>
    """
  end

  attr :item, :map, required: true

  defp row_text(assigns) do
    ~H"""
    <span class="proposal-row-text">
      <span class="proposal-row-title">
        {@item.title || "Could not be read"}
        <span :if={@item.suggested} class="ui-type-badge">{@item.suggested}</span>
      </span>
      <span class="proposal-row-body">{@item.body}</span>
    </span>
    """
  end

  @doc "Whether a group is all, some or none selected, as `aria-checked` says it."
  @spec group_state(group(), MapSet.t()) :: String.t()
  def group_state(group, selected) do
    picked = Enum.count(group.items, &MapSet.member?(selected, &1.version_id))

    cond do
      picked == 0 -> "false"
      picked == length(group.items) -> "true"
      true -> "mixed"
    end
  end

  defp box_mark("true"), do: "✓"
  defp box_mark("mixed"), do: "–"
  defp box_mark("false"), do: ""

  # -- the reader -------------------------------------------------------------------------

  @doc """
  One proposal at reading size (`8b`): where it came from above its title, the whole body,
  **Admit** with the type to admit it as, **Skip** and **Decline** with a reason. Skip is the
  page's and writes nothing. A proposal a chat wrote can be asked about: the composer sends to that
  chat. One a ticket's job wrote has no chat, and draws no composer.
  """
  attr :item, :map, required: true
  attr :group, :map, required: true
  attr :position, :any, required: true, doc: "`{n, of}` over every open proposal"
  attr :types, :list, default: []
  attr :drafts, :map, required: true
  attr :error, :string, default: nil
  attr :now, :any, required: true

  def reader(assigns) do
    assigns =
      assign(assigns,
        draft: "propose-#{assigns.item.version_id}",
        typeless: typeless?(assigns.types, chosen(assigns.drafts, assigns.item)),
        in_group:
          Enum.find_index(assigns.group.items, &(&1.version_id == assigns.item.version_id)) + 1
      )

    ~H"""
    <article id="proposal-reader" class="proposal-reader" data-version={@item.version_id}>
      <p class="proposal-reader-position">
        {elem(@position, 0)} of {elem(@position, 1)}
      </p>
      <p class="proposal-reader-source">
        From {@group.source} · {Format.ago(@item.at, @now)} · {@in_group} of {length(@group.items)}
      </p>
      <h2 class="proposal-reader-title">{@item.title || "Could not be read"}</h2>
      <div :if={@item.readable} class="doc proposal-reader-body">
        {Markdown.to_html(@item.body, %{})}
      </div>
      <.notice :if={not @item.readable} tone="danger" title="This cannot be read as a proposal">
        It cannot be admitted. Decline it. {@item.body}
      </.notice>

      <p :if={@item.suggested && @types != []} class="proposal-suggestion">
        {suggestion(@item.suggested, @types)}
      </p>

      <form
        id={@draft}
        phx-change="draft:change"
        phx-submit="decide_proposal"
        class="proposal-reader-form"
      >
        <input type="hidden" name="draft" value={@draft} />
        <input type="hidden" name="version_id" value={@item.version_id} />
        <%!-- The chosen type is part of the draft too: a reconnect that put the comment back and
              not the choice would still have taken something nobody was told about. --%>
        <label :if={@types != [] and @item.readable} class="proposal-type">
          <span class="ui-field-label">Admit as</span>
          <select name="ticket_type" class="ui-field-input" aria-label="Ticket type">
            <option value="">Choose a type</option>
            <option
              :for={type <- @types}
              value={type.name}
              selected={type.name == chosen(@drafts, @item)}
            >
              {if type.parses, do: type.name, else: "#{type.name} — does not parse"}
            </option>
          </select>
        </label>
        <%!-- Enter breaks a line: a one-line input submitted with the first button
              (`docs/design/ui.md` § The affordance rule). --%>
        <ForgeWeb.Conversations.message_box
          id={"proposal-comment-#{@item.version_id}"}
          name="comment"
          value={Drafts.field(@drafts, @draft, "comment")}
          enter={:newline}
          label="Note, optional"
          placeholder="Kept with the decision: why it was declined, or why it was admitted"
        />
        <.error_note :if={@error} id="proposal-error">{@error}</.error_note>
        <%!-- Admit waits for a type where there is one to choose: the server refuses it without,
              and a button that is pressed only to be told so is the wrong way round. --%>
        <p :if={@item.readable and @typeless} id="proposal-admit-why" class="proposal-admit-why">
          Choose a type to admit it.
        </p>
        <div class="proposal-actions">
          <.button
            type="button"
            variant="secondary"
            phx-click="proposals:skip"
            phx-value-id={@item.version_id}
          >
            Skip
          </.button>
          <.button
            type="submit"
            name="decision"
            value="declined"
            variant="secondary"
            phx-disable-with="Declining…"
          >
            Decline
          </.button>
          <.button
            :if={@item.readable}
            type="submit"
            name="decision"
            value="accepted"
            variant="decision"
            fill
            disabled={@typeless}
            phx-disable-with="Admitting…"
          >
            Admit
          </.button>
        </div>
      </form>

      <form
        :if={@group.chat}
        id="proposal-ask"
        phx-change="draft:change"
        phx-submit="proposal:ask"
        class="proposal-ask"
      >
        <input type="hidden" name="draft" value="ask" />
        <input type="hidden" name="version_id" value={@item.version_id} />
        <.composer
          id="proposal-ask-text"
          name="text"
          value={Drafts.field(@drafts, "ask", "text")}
          placeholder="Ask the chat about this"
        />
      </form>
    </article>
    """
  end

  # The type a proposal's select is drawn on: what the person chose if they chose, and the
  # suggestion until they do. `Drafts.field/4` cannot carry the fallback, because choosing the
  # empty option is a choice — *Choose a type*, deliberately back to nothing — and a draft holding
  # `""` must beat the suggestion rather than fall through to it.
  defp chosen(drafts, item) do
    case Drafts.field(drafts, "propose-#{item.version_id}", "ticket_type", nil) do
      nil -> item[:suggested]
      type -> type
    end
  end

  # Whether Admit has a type to admit as where it must have one: nothing chosen, or a suggestion
  # that is not a type here, which the select cannot show as chosen either.
  defp typeless?([], _chosen), do: false
  defp typeless?(types, chosen), do: not Enum.any?(types, &(&1.name == chosen))

  # The suggestion said in words, so a person can see why the select starts where it does.
  defp suggestion(type, types) do
    if Enum.any?(types, &(&1.name == type)),
      do: "suggests #{type}",
      else: "suggests #{type}, which is not a type here"
  end

  # -- selecting --------------------------------------------------------------------------

  @doc """
  The bulk bar (`8c`, `8f`): how many are picked, the type to admit them as, one shared reason,
  and the two verbs. Declining several is refused whole when any one is not the actor's to
  decline (`Forge.Operator.decline_proposals/3`).
  """
  attr :count, :integer, required: true
  attr :types, :list, default: []
  attr :drafts, :map, required: true
  attr :error, :string, default: nil

  def bulk(assigns) do
    assigns =
      assign(assigns,
        typeless: typeless?(assigns.types, Drafts.field(assigns.drafts, "bulk", "ticket_type"))
      )

    ~H"""
    <form
      id="proposal-bulk"
      phx-change="draft:change"
      phx-submit="proposals:bulk"
      class="proposal-bulk"
    >
      <input type="hidden" name="draft" value="bulk" />
      <div class="proposal-bulk-head">
        <span class="proposal-bulk-count">{@count} selected</span>
        <select :if={@types != []} name="ticket_type" class="ui-field-input" aria-label="Admit as">
          <option value="">Choose a type</option>
          <option
            :for={type <- @types}
            value={type.name}
            selected={type.name == Drafts.field(@drafts, "bulk", "ticket_type")}
          >
            {type.name}
          </option>
        </select>
      </div>
      <ForgeWeb.Conversations.message_box
        id="proposal-bulk-reason"
        name="reason"
        value={Drafts.field(@drafts, "bulk", "reason")}
        enter={:newline}
        placeholder="One reason for every one declined, optional"
        aria-label="Shared reason, optional"
      />
      <.error_note :if={@error} id="bulk-error">{@error}</.error_note>
      <div class="proposal-actions">
        <.button type="submit" name="bulk" value="decline" variant="secondary">
          Decline {@count}
        </.button>
        <.button
          type="submit"
          name="bulk"
          value="admit"
          variant="decision"
          fill
          disabled={@typeless}
          title={@typeless && "Choose a type to admit them"}
        >
          Admit {@count}
        </.button>
      </div>
    </form>
    """
  end

  # -- the history ------------------------------------------------------------------------

  @doc """
  What became of them (`8d`): admitted ones link to the ticket they became and show where it is
  now; declined ones keep their reason, and one whose declined version is still its latest can be
  reopened. One reopened since says so, and its open self is back in the list.
  """
  attr :entries, :list, required: true, doc: "`Forge.Proposals.decided/1`, flattened"
  attr :project, :string, required: true
  attr :viewer, :string, required: true, doc: "the viewer's user id"
  attr :now, :any, required: true

  def history(assigns) do
    # Each ticket's mark from one parse per workflow pin, not one per entry (`Topology.kinds/1`).
    # Parsing per entry again draws the same marks: an equivalent mutant no page test can see,
    # since only the cost differs.
    assigns =
      assign(assigns, :kinds, Topology.kinds(for e <- assigns.entries, e.ticket, do: e.ticket))

    ~H"""
    <ol id="proposal-history" class="proposal-history">
      <li
        :for={entry <- @entries}
        id={"decided-#{entry.version_id}"}
        class={[
          "proposal-decided",
          (entry.decision == :declined and not entry.latest) && "proposal-decided--reopened"
        ]}
      >
        <div class="proposal-decided-head">
          <span class="proposal-row-title">{entry.title}</span>
          <span class="proposal-group-meta">{Format.ago(entry.at, @now)}</span>
        </div>
        <div :if={entry.decision == :accepted} class="proposal-decided-line">
          <.link
            :if={entry.ticket}
            navigate={~p"/tickets/#{@project}/#{entry.ticket.number}"}
            class="project-link"
          >
            → #{entry.ticket.number}
          </.link>
          <Indicators.state
            :if={entry.ticket}
            name={entry.ticket.state}
            topology={@kinds[entry.ticket.id]}
          />
          <Indicators.status :if={entry.ticket} status={entry.ticket.status} />
        </div>
        <div :if={entry.decision == :declined} class="proposal-decided-line">
          <span class="proposal-declined">○ declined</span>
          <span :if={entry.comment} class="proposal-reason">“{entry.comment}”</span>
        </div>
        <p class="proposal-decided-by">
          from {entry.source} · by {if entry.user_id == @viewer, do: "you", else: "a member"}
        </p>
        <.button
          :if={entry.decision == :declined and entry.latest}
          type="button"
          id={"reopen-#{entry.version_id}"}
          variant="outline"
          size="sm"
          phx-click="proposal:reopen"
          phx-value-id={entry.version_id}
          phx-disable-with="Reopening…"
        >
          Reopen
        </.button>
        <p :if={entry.decision == :declined and not entry.latest} class="proposal-decided-by">
          reopened since
        </p>
      </li>
      <li :if={@entries == []} class="project-empty">Nothing here yet.</li>
    </ol>
    """
  end

  @doc """
  Whether a decided entry is a proposal that is declined **now**: its declined version is still
  the latest. One reopened since is open again, and counting it under Declined as well counted it
  in two lists at once.
  """
  @spec still_declined?(map()) :: boolean()
  def still_declined?(entry), do: entry.decision == :declined and entry.latest

  @doc "A decided proposal flattened for `history/1`."
  @spec entry(map(), map(), map()) :: map()
  def entry(decided, tickets, openings) do
    title =
      case ForgeCore.Proposal.parse(decided.version.content || "") do
        {:ok, proposal} -> proposal.title
        {:error, _errors} -> decided.artifact.name
      end

    %{
      version_id: decided.version.id,
      title: title,
      decision: decided.decision.decision,
      comment: decided.decision.comment,
      user_id: decided.decision.user_id,
      at: decided.decision.inserted_at,
      ticket: decided.ticket,
      latest: decided.latest,
      source: source(decided.job, tickets, openings)
    }
  end
end
