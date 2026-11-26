defmodule ForgeWeb.MilestonesView do
  @moduledoc """
  The project page's Milestones view (`docs/design/ui.md` § Milestones): the current milestone
  first, then the other open ones in their order, then the tickets in no milestone, each list in
  its priority order, and the closed milestones folded at the end.

  **One row, three ways to order it.** Every ticket row has move buttons (to the top, up one, down
  one) and a drag handle, and a *Move to* select for its milestone; a phone can do all of it, and
  each does the same thing — one `Forge.Operator.move_ticket/3` — so a drag is never the only way.
  The drag is a colocated hook on pointer events (HTML5 drag and drop is poor on touch), pushes one
  event on pointer-up and nothing before it, and **cancels and restores the order when the
  connection drops**, so a drag cut off by a reconnect moves nothing (`docs/design/ui.md` § A
  reconnect is not a reload).

  A ticket on hold shows *on hold* and **Release**, a refusal of which is said on its own row; one
  that is taken over shows *taken over* and **Hand back**, which hands it back to the step it rests
  in with no note (`Forge.Operator.release/3`). None
  of it is drawn in the colour that means waiting on you, because nothing is.

  Text a person wrote — a name, a description, a title — is drawn as text and wrapped, never as
  markup and never wider than its column.
  """

  use ForgeWeb, :html

  alias Forge.Engine
  alias Forge.Milestones.Milestone
  alias ForgeWeb.Operator.{Actions, Drafts}

  @doc "The view. `overview` is `Forge.Milestones.overview/1`; `refusal` the page's last refusal."
  attr :overview, :map, required: true
  attr :project, :any, required: true
  attr :drafts, :map, required: true
  attr :refusal, :map, default: nil

  def view(assigns) do
    assigns =
      assign(assigns,
        open: Enum.map(assigns.overview.milestones, & &1.milestone),
        count: length(assigns.overview.milestones)
      )

    ~H"""
    <section id="project-milestones" class="project-section" data-section="milestones">
      <div class="project-section-head">
        <.eyebrow>Milestones · {@count}</.eyebrow>
      </div>

      <Actions.refused id="milestones-refusal" refusal={@refusal} at={["milestones"]} />

      <form
        id="milestone-create"
        phx-change="draft:change"
        phx-submit="milestones:create"
        class="ms-create"
      >
        <input type="hidden" name="draft" value="milestone-create" />
        <label class="ms-field">
          <span class="ui-field-label">New milestone</span>
          <input
            type="text"
            name="name"
            class="ui-field-input"
            autocomplete="off"
            maxlength={Milestone.name_limit() * 2}
            placeholder="Name it after the goal"
            value={Drafts.field(@drafts, "milestone-create", "name")}
          />
        </label>
        <.button type="submit" variant="outline" size="md">Create</.button>
      </form>

      <p :if={@count == 0} id="milestones-none" class="project-empty">
        A milestone is a named goal — what the next few tickets are for. Create one above, put
        tickets in it, order them, and release the top one when it is its turn.
        <span :if={@overview.closed != []}>
          Every milestone here is closed: reopen one below, or create a new one.
        </span>
      </p>
      <p
        :if={@count > 0 and @overview.current == nil}
        id="milestones-no-current"
        class="project-empty"
      >
        No milestone is marked current. Mark one with <em>Make current</em> and it comes first.
      </p>

      <div
        id="ms-list"
        class="ms-list"
        phx-hook=".SortableRows"
        data-key="milestone"
        data-event="milestones:drag_milestone"
      >
        <.card
          :for={entry <- ordered(@overview)}
          pinned={entry.milestone.current}
          first={first_open?(@overview, entry)}
          last={last_open?(@overview, entry)}
          entry={entry}
          open={@open}
          drafts={@drafts}
          refusal={@refusal}
          project={@project}
        />
      </div>

      <div id="ms-unplaced" class="ms-card">
        <div class="ms-head">
          <.eyebrow>No milestone · {length(@overview.unplaced)}</.eyebrow>
        </div>
        <.rows
          id="ms-rows-none"
          list="none"
          tickets={@overview.unplaced}
          open={@open}
          refusal={@refusal}
          project={@project}
          empty="No tickets are waiting outside a milestone."
        />
      </div>

      <details :if={@overview.closed != []} id="ms-closed" class="ms-closed">
        <summary class="ticket-history-summary">
          <span class="ticket-history-mark" aria-hidden="true">▸</span>
          <.eyebrow>Closed · {length(@overview.closed)}</.eyebrow>
        </summary>
        <div
          :for={entry <- @overview.closed}
          id={"ms-closed-#{entry.milestone.id}"}
          class="ms-closed-row"
        >
          <span class="ms-name">{entry.milestone.name}</span>
          <span class="ms-progress">{progress(entry.progress)}</span>
          <.button
            type="button"
            variant="outline"
            size="sm"
            phx-click="milestones:reopen"
            phx-value-id={entry.milestone.id}
          >
            Reopen
          </.button>
        </div>
      </details>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SortableRows">
        // Dragging a row by its handle. Pointer events, not HTML5 drag and drop, which is poor on
        // touch. The DOM is reordered under the finger and **one** event is pushed on pointer-up:
        // the id of the row and of the row it now sits before (nothing: the bottom). A drag the
        // connection outlives is not a drag the server hears of — when the socket drops, the order
        // is put back and nothing is sent (`docs/design/ui.md` § A reconnect is not a reload).
        export default {
          mounted() {
            this.drag = null
            this.onDown = (event) => {
              const handle = event.target.closest("[data-handle]")
              if (!handle || !this.el.contains(handle) || (event.button ?? 0) !== 0) return
              const row = handle.closest("[data-id]")
              // Only this list's own rows: a ticket's handle sits inside a milestone's card, in a
              // list of its own, and bubbles up to this one.
              if (!row || row.parentElement !== this.el) return
              event.preventDefault()
              handle.setPointerCapture?.(event.pointerId)
              this.drag = {row, handle, pointer: event.pointerId, order: this.order()}
              row.classList.add("ms-row--dragging")
            }
            this.onMove = (event) => {
              if (!this.drag || event.pointerId !== this.drag.pointer) return
              const over = document.elementFromPoint(event.clientX, event.clientY)
              // The child of this list the pointer is over, or inside: a milestone's card is dragged
              // over another card's ticket rows, which are rows of a list of their own.
              let other = over
              while (other && other.parentElement !== this.el) other = other.parentElement
              if (!other || other === this.drag.row) return
              const box = other.getBoundingClientRect()
              const after = event.clientY > box.top + box.height / 2
              this.el.insertBefore(this.drag.row, after ? other.nextSibling : other)
            }
            this.onUp = (event) => {
              if (!this.drag || event.pointerId !== this.drag.pointer) return
              const {row, order} = this.drag
              this.finish()
              const now = this.order()
              if (now.join() === order.join()) return
              const next = row.nextElementSibling
              const payload = {before: next ? next.dataset.id : null}
              payload[this.el.dataset.key] = row.dataset.id
              // The server answers whether the order stands: where it refused, or kept the old one,
              // the order drawn under the finger is put back.
              this.pushEvent(this.el.dataset.event, payload, (reply) => {
                if (reply && reply.restore) this.restore(order)
              })
            }
            this.onCancel = () => this.cancel()
            this.el.addEventListener("pointerdown", this.onDown)
            this.el.addEventListener("pointermove", this.onMove)
            this.el.addEventListener("pointerup", this.onUp)
            this.el.addEventListener("pointercancel", this.onCancel)
          },
          disconnected() { this.cancel() },
          destroyed() { this.cancel() },
          order() { return Array.from(this.el.children).map((li) => li.dataset.id) },
          finish() {
            if (!this.drag) return
            this.drag.row.classList.remove("ms-row--dragging")
            this.drag.handle.releasePointerCapture?.(this.drag.pointer)
            this.drag = null
          },
          cancel() {
            if (!this.drag) return
            const {order} = this.drag
            this.finish()
            this.restore(order)
          },
          restore(order) {
            const byId = new Map(Array.from(this.el.children).map((li) => [li.dataset.id, li]))
            order.forEach((id) => byId.has(id) && this.el.appendChild(byId.get(id)))
          }
        }
      </script>
    </section>
    """
  end

  # The current milestone first, then the others in their order (`Forge.Milestones.overview/1`
  # returns them in order and a current one is among them).
  defp ordered(%{milestones: entries}) do
    {current, others} = Enum.split_with(entries, & &1.milestone.current)
    current ++ others
  end

  # The milestones that are ordered: the open ones but the current, which is drawn first.
  defp movable(%{milestones: entries}),
    do: entries |> Enum.reject(& &1.milestone.current) |> Enum.map(& &1.milestone.id)

  defp first_open?(overview, entry), do: List.first(movable(overview)) == entry.milestone.id
  defp last_open?(overview, entry), do: List.last(movable(overview)) == entry.milestone.id

  @doc """
  Where a move of milestone `id` goes, worked out against the order the view draws: the current
  milestone is pinned first and takes no part, the others are in the order they are stored in. So
  *up one* is above the one drawn above it, and a card dropped above the current one lands first
  among the rest. `{:ok, to}` for `Forge.Milestones.move/4`, or `:same` where nothing would move:
  the current milestone, one that is not open here, or a move to where it already is.
  """
  @spec target(map(), String.t(), term()) :: {:ok, Forge.Milestones.to()} | :same
  def target(overview, id, to) do
    ids = movable(overview)

    case Enum.find_index(ids, &(&1 == id)) do
      nil -> :same
      index -> aim(ids, id, index, to, current_id(overview))
    end
  end

  defp current_id(%{milestones: entries}),
    do: Enum.find_value(entries, &(&1.milestone.current && &1.milestone.id))

  defp aim(ids, id, _index, :top, _current), do: before(ids, id, hd(ids))

  defp aim(ids, id, index, :up, _current) when index > 0,
    do: before(ids, id, Enum.at(ids, index - 1))

  defp aim(_ids, _id, 0, :up, _current), do: :same

  defp aim(ids, id, index, :down, _current) when index < length(ids) - 1,
    do: after_next(ids, id, index)

  defp aim(_ids, _id, _last, :down, _current), do: :same

  defp aim(ids, id, _index, :bottom, _current),
    do: if(List.last(ids) == id, do: :same, else: {:ok, :bottom})

  # Dropped above `other`: above the current one is first among the rest; above one that is not
  # drawn at all is for the operator to refuse.
  defp aim(ids, id, _index, {:before, other}, current) do
    cond do
      other == id -> :same
      other == current -> before(ids, id, hd(ids))
      other in ids -> before(ids, id, other)
      true -> {:ok, {:before, other}}
    end
  end

  defp before(ids, id, other) do
    if other == id or Enum.at(ids, Enum.find_index(ids, &(&1 == id)) + 1) == other,
      do: :same,
      else: {:ok, {:before, other}}
  end

  defp after_next(ids, _id, index) do
    case Enum.at(ids, index + 2) do
      nil -> {:ok, :bottom}
      following -> {:ok, {:before, following}}
    end
  end

  attr :entry, :map, required: true
  attr :open, :list, required: true
  attr :drafts, :map, required: true
  attr :refusal, :map, default: nil
  attr :project, :any, required: true
  attr :pinned, :boolean, required: true
  attr :first, :boolean, required: true
  attr :last, :boolean, required: true

  defp card(assigns) do
    assigns = assign(assigns, :m, assigns.entry.milestone)

    ~H"""
    <article
      id={"ms-#{@m.id}"}
      data-id={@m.id}
      class={["ms-card", @m.current && "ms-card--current"]}
    >
      <div class="ms-head">
        <span
          :if={not @pinned}
          class="ms-handle"
          data-handle
          aria-hidden="true"
          title="Drag to reorder"
        >
          ⠿
        </span>
        <h3 class="ms-name">
          {@m.name}
          <span :if={@m.current} class="ms-mark">current</span>
        </h3>
        <div class="ms-actions">
          <.button
            type="button"
            variant="quiet"
            size="sm"
            phx-click="milestones:current"
            phx-value-id={if @m.current, do: "", else: @m.id}
          >
            {if @m.current, do: "Unmark", else: "Make current"}
          </.button>
          <%!-- The current milestone is drawn first whatever its place, so there is nowhere for it to
                go; the others are ordered among themselves. --%>
          <.button
            type="button"
            variant="quiet"
            size="sm"
            disabled={@pinned or @first}
            phx-click="milestones:move"
            phx-value-id={@m.id}
            phx-value-to="top"
            aria-label={"Move #{@m.name} to the top"}
          >
            Top
          </.button>
          <.button
            type="button"
            variant="quiet"
            size="sm"
            disabled={@pinned or @first}
            phx-click="milestones:move"
            phx-value-id={@m.id}
            phx-value-to="up"
            aria-label={"Move #{@m.name} up"}
          >
            ↑
          </.button>
          <.button
            type="button"
            variant="quiet"
            size="sm"
            disabled={@pinned or @last}
            phx-click="milestones:move"
            phx-value-id={@m.id}
            phx-value-to="down"
            aria-label={"Move #{@m.name} down"}
          >
            ↓
          </.button>
        </div>
      </div>
      <p :if={@m.description} class="ms-description">{@m.description}</p>
      <p class="ms-progress" id={"ms-progress-#{@m.id}"}>{progress(@entry.progress)}</p>
      <Actions.refused id={"ms-refusal-#{@m.id}"} refusal={@refusal} at={[{:milestone, @m.id}]} />

      <.rows
        id={"ms-rows-#{@m.id}"}
        list={@m.id}
        tickets={@entry.open}
        open={@open}
        refusal={@refusal}
        project={@project}
        empty="No tickets yet. Put one here from its row, or choose this milestone when admitting."
      />

      <details :if={@entry.merged != []} class="ms-merged">
        <summary class="ticket-history-summary">
          <span class="ticket-history-mark" aria-hidden="true">▸</span>
          <.eyebrow>Merged · {length(@entry.merged)}</.eyebrow>
        </summary>
        <ol class="ms-merged-list">
          <li :for={t <- @entry.merged}>
            <.link navigate={~p"/tickets/#{@project.name}/#{t.number}"} class="ms-merged-row">
              <span class="ticket-row-number">#{t.number}</span>
              <span class="ms-title">{t.title}</span>
            </.link>
          </li>
        </ol>
      </details>

      <details class="ms-edit">
        <summary class="ms-edit-summary">Rename, describe or close</summary>
        <form
          id={"ms-edit-#{@m.id}"}
          phx-change="draft:change"
          phx-submit="milestones:update"
          class="ms-edit-form"
        >
          <input type="hidden" name="draft" value={"ms-edit-#{@m.id}"} />
          <input type="hidden" name="milestone" value={@m.id} />
          <label class="ms-field">
            <span class="ui-field-label">Name</span>
            <input
              type="text"
              name="name"
              class="ui-field-input"
              autocomplete="off"
              value={Drafts.field(@drafts, "ms-edit-#{@m.id}", "name", @m.name)}
            />
          </label>
          <label class="ms-field">
            <span class="ui-field-label">Description</span>
            <textarea name="description" rows="3" class="ui-field-input">{Drafts.field(@drafts, "ms-edit-#{@m.id}", "description", @m.description || "")}</textarea>
          </label>
          <div class="ms-edit-actions">
            <.button type="submit" variant="outline" size="md">Save</.button>
            <.confirm
              id={"ms-close-#{@m.id}"}
              label="Close"
              act="Close it"
              sentence="Close this milestone? Its open tickets move out of it, to the bottom of the tickets in none; reopening does not bring them back."
              size="md"
              phx-click="milestones:close"
              phx-value-id={@m.id}
            />
          </div>
        </form>
      </details>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :list, :string, required: true
  attr :tickets, :list, required: true
  attr :open, :list, required: true
  attr :refusal, :map, default: nil
  attr :project, :any, required: true
  attr :empty, :string, required: true

  # One list of rows in priority order. `data-key` and `data-event` are what the drag hook pushes.
  defp rows(assigns) do
    ~H"""
    <p :if={@tickets == []} class="ms-empty">{@empty}</p>
    <ol
      :if={@tickets != []}
      id={@id}
      class="ms-rows"
      phx-hook=".SortableRows"
      data-key="ticket"
      data-event="milestones:drag"
    >
      <li
        :for={{t, index} <- Enum.with_index(@tickets)}
        id={"#{@id}-#{t.number}"}
        data-id={t.id}
        class={["ms-row", Forge.Tickets.Ticket.held?(t) && "ms-row--held"]}
      >
        <span class="ms-handle" data-handle aria-hidden="true" title="Drag to reorder">⠿</span>
        <div class="ms-row-body">
          <.link navigate={~p"/tickets/#{@project.name}/#{t.number}"} class="ms-row-link">
            <span class="ticket-row-number">#{t.number}</span>
            <span class="ms-title">{t.title}</span>
          </.link>
          <div class="ms-row-meta">
            <span class="ms-state">{t.state}</span>
            <span :if={t.status == :stuck} class="ms-flag ms-flag--stuck">stuck</span>
            <span :if={Forge.Tickets.Ticket.held?(t)} class="ms-flag ms-flag--held">
              {if Forge.Tickets.Ticket.taken_over?(t),
                do: "taken over · #{t.holder || "someone"}",
                else: "on hold"}
            </span>
            <span :if={waits(t)} class="ms-waits">{waits(t)}</span>
          </div>
          <Actions.refused id={"ms-row-refusal-#{t.id}"} refusal={@refusal} at={[{:row, t.id}]} />
        </div>
        <div class="ms-row-actions">
          <.button
            :if={Forge.Tickets.Ticket.held?(t)}
            type="button"
            variant="outline"
            size="sm"
            phx-click="milestones:release"
            phx-value-ticket={t.id}
          >
            {if Forge.Tickets.Ticket.taken_over?(t), do: "Hand back", else: "Release"}
          </.button>
          <.move ticket={t} to="top" label="Move to the top" disabled={index == 0}>Top</.move>
          <.move ticket={t} to="up" label="Move up one" disabled={index == 0}>↑</.move>
          <.move
            ticket={t}
            to="down"
            label="Move down one"
            disabled={index == length(@tickets) - 1}
          >
            ↓
          </.move>
          <form phx-change="milestones:place" phx-auto-recover="ignore" class="ms-place">
            <input type="hidden" name="ticket" value={t.id} />
            <select name="milestone" class="ui-field-input" aria-label={"Move ##{t.number} to"}>
              <option value="" selected={t.milestone_id == nil}>No milestone</option>
              <option :for={m <- @open} value={m.id} selected={m.id == t.milestone_id}>
                {m.name}
              </option>
            </select>
          </form>
        </div>
      </li>
    </ol>
    """
  end

  attr :ticket, :map, required: true
  attr :to, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  defp move(assigns) do
    ~H"""
    <.button
      type="button"
      variant="quiet"
      size="sm"
      disabled={@disabled}
      phx-click="milestones:ticket_move"
      phx-value-ticket={@ticket.id}
      phx-value-to={@to}
      aria-label={"#{@label}: ##{@ticket.number}"}
    >
      {render_slot(@inner_block)}
    </.button>
    """
  end

  # What a held ticket does when released, in the words the page uses for the hold.
  defp waits(%{held_at: nil}), do: nil

  defp waits(ticket) do
    case Engine.waiting_on_release(ticket) do
      {:transition, _from, to, _outcome} -> "moves to #{to} when released"
      {:entry, state} -> "starts #{state} when released"
      nil -> nil
    end
  end

  @doc "The figure beside a milestone's name: merged out of open and merged, and what is open."
  @spec progress(map()) :: String.t()
  def progress(%{merged: merged, total: total, on_hold: on_hold, in_flight: in_flight}) do
    "#{merged} of #{total} merged · #{on_hold} on hold · #{in_flight} in flight"
  end
end
