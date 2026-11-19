defmodule ForgeWeb.QueuePast do
  @moduledoc """
  The ticket's past, as the queue draws it on every item about a ticket (`docs/design/ui.md` §
  What each kind shows, *Every item about a ticket*): a line per step, then the loops that have
  fired. `Forge.Tickets.Past` reads it; this draws it and decides nothing.

  The lines are one form, so that **opening one is a change the page can replay**: a rejoin sends
  the form's checked boxes back and the line comes back open (`docs/design/ui.md` § A reconnect is
  not a reload). Everything here is a text node — an agent's closing words, a log, a reply, a
  workflow's own names — and nothing is drawn as markup.
  """

  use ForgeWeb, :html

  alias ForgeWeb.{Format, TicketViews}

  attr :item, :map, required: true
  attr :detail, :map, required: true

  @doc """
  The step lines and the loops of the item on screen, inside the item itself at every width.
  `detail.opened` is the step whose line is open, `detail.run` what its latest run said.
  """
  def past(assigns) do
    assigns =
      assign(assigns,
        steps: assigns.detail[:past] || [],
        loops: assigns.detail[:loops] || [],
        opened: assigns.detail[:opened]
      )

    ~H"""
    <section :if={@steps != []} id="queue-past" class="queue-past">
      <.eyebrow>Where it has been</.eyebrow>
      <form id={"queue-past-#{@item.key}"} phx-change="queue:step">
        <input type="hidden" name="item" value={@item.key} />
        <ol class="queue-steps">
          <li
            :for={step <- @steps}
            id={"queue-step-#{step.name}"}
            class={["queue-step", step.current && "queue-step--current"]}
            data-open={@opened == step.name}
          >
            <label :if={openable?(step, @item)} class="queue-step-line queue-step-line--open">
              <input
                type="checkbox"
                name="open[]"
                value={step.name}
                checked={@opened == step.name}
                class="queue-step-toggle"
              />
              <span class="queue-step-text">{line(step)}</span>
              <span class="queue-step-chevron" aria-hidden="true">›</span>
            </label>
            <div :if={!openable?(step, @item)} class="queue-step-line">
              <span class="queue-step-text">{line(step)}</span>
            </div>
            <.run :if={@opened == step.name && @detail[:run]} item={@item} run={@detail.run} />
          </li>
        </ol>
      </form>
      <ul :if={@loops != []} id="queue-loops" class="queue-loops">
        <li :for={loop <- @loops} class="queue-loop">
          <span class="queue-loop-edge">{loop.from} → {loop.to} on {loop.outcome}</span>
          <span class="queue-loop-rounds">{rounds(loop)}</span>
        </li>
      </ul>
    </section>
    """
  end

  # A line opens when there is a run to show: a human step has none, a step that never ran has
  # none, and on a stuck item the current step's latest run is the last attempt drawn below.
  @doc false
  def openable?(%{kind: :human}, _item), do: false
  def openable?(%{kind: :update}, _item), do: false
  def openable?(%{runs: 0}, _item), do: false
  def openable?(%{current: true}, %{kind: :stuck}), do: false
  def openable?(_step, _item), do: true

  # *implementing · 4 runs · last converged*, *checking · not run yet*, *review_ready · 2 visits*.
  # A count is a plain number however large.
  @doc false
  def line(%{kind: :human, name: name, runs: runs}),
    do: "#{name} · #{Format.counted(runs, "visit")}"

  # An update step has visits, as a human one, and says what the latest did: *refresh · 2 visits ·
  # last moved forward to abc123*.
  def line(%{kind: :update, name: name, runs: runs, last: last}),
    do:
      Enum.join(
        Enum.reject([name, Format.counted(runs, "visit"), last && "last #{last}"], &is_nil/1),
        " · "
      )

  def line(%{name: name, runs: 0}), do: "#{name} · not run yet"

  def line(%{name: name, runs: runs, last: last}),
    do:
      Enum.join(
        Enum.reject([name, Format.counted(runs, "run"), last && "last #{last}"], &is_nil/1),
        " · "
      )

  defp rounds(%{rounds: rounds, max: nil}), do: "#{rounds}"
  defp rounds(%{rounds: rounds, max: max}), do: "#{rounds} of #{max}"

  attr :item, :map, required: true
  attr :run, :map, required: true

  defp run(%{run: %{kind: :agent}} = assigns) do
    ~H"""
    <div id="queue-run" class="queue-run">
      <span class="queue-attempt-head">
        #{@run.job.attempt}
        <span class="queue-attempt-outcome">
          {@run.job.declared_outcome || @run.job.outcome || @run.job.status}
        </span>
        · {Format.counted(@run.job.turns, "turn")} · {Format.duration(@run.job)}
      </span>
      <.clamped :if={@run.closing} id="queue-run-said" text={"agent: “#{@run.closing}”"} />
      <.link navigate={job_path(@item, @run.job)} class="queue-link">The job ›</.link>
    </div>
    """
  end

  defp run(%{run: %{kind: :command}} = assigns) do
    ~H"""
    <div id="queue-run" class="queue-run">
      <.batch item={@item} batch={@run} />
    </div>
    """
  end

  defp run(%{run: %{kind: :conversation}} = assigns) do
    ~H"""
    <div id="queue-run" class="queue-run">
      <.clamped :if={@run.reply} id="queue-run-said" text={@run.reply} />
      <p :if={!@run.reply} class="queue-quiet">It has said nothing yet.</p>
      <.link navigate={~p"/chats/#{@run.job.id}"} class="queue-link">Open the chat ›</.link>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :batch, :map, required: true

  @doc """
  A command batch drawn as the ticket's Steps view draws it: each command with its exit status,
  and for a failed one the end of its log (`Forge.Jobs.Commands.latest_batch/3`).
  """
  def batch(assigns) do
    ~H"""
    <ol class="queue-commands ticket-jobs">
      <li :for={job <- @batch.jobs}>
        <TicketViews.command_row job={job} project={%{name: @item.project}} ticket={@item.ticket} />
        <pre
          :if={@batch.tails[job.id]}
          id={"queue-command-#{job.id}-tail"}
          class="ticket-tail"
        >{@batch.tails[job.id]}</pre>
      </li>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :class, :string, default: nil

  @doc """
  A passage clamped to four lines on a phone with *more* at its end, which unclamps it in the
  browser — sticky across patches, as a JS class is. Only a passage that would run past four lines
  is clamped: a short one never offers to show what it already shows.
  """
  def clamped(assigns) do
    assigns = assign(assigns, long: long?(assigns.text))

    ~H"""
    <p id={@id} class={["queue-said", @class, @long && "queue-said--clamped"]}>{@text}</p>
    <button
      :if={@long}
      id={"#{@id}-more"}
      type="button"
      class="queue-said-more"
      phx-click={JS.remove_class("queue-said--clamped", to: "##{@id}") |> JS.hide(to: "##{@id}-more")}
    >
      more
    </button>
    """
  end

  # Whether a passage would run past four lines at a phone's measure — about 45 characters a line
  # at 14px in 372px — or holds more than four lines of its own.
  @clamp_chars 180
  @clamp_lines 4

  @doc false
  def long?(text) when is_binary(text),
    do:
      String.length(text) > @clamp_chars or
        length(String.split(text, "\n")) > @clamp_lines

  def long?(_none), do: false

  defp job_path(item, job), do: ~p"/tickets/#{item.project}/#{item.ticket.number}/jobs/#{job.id}"
end
