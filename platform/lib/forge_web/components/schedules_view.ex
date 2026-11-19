defmodule ForgeWeb.SchedulesView do
  @moduledoc """
  The schedules a workflow file declares, drawn in each type's section of the project page's
  Workflow view (`docs/design/ui.md` § Workflow, `docs/design/schedules.md`).

  Every member sees each schedule's name, its cron line and what it means in words, the next time
  it fires in the reader's own time, whether it is on and by whom, the ticket it last admitted and
  its problem in the warning tone. **A project admin sees the switch and a member does not** — a
  cosmetic split, because `Forge.Operator` refuses a member's `schedule:on` however it arrives.
  Switching on asks first, in words, and says whose name each ticket is admitted in; switching off
  does not ask.

  **Everything a file wrote is text.** A name, a title, a body and a cron line come from a
  repository anyone with a merge may push to, and are drawn escaped and wrapped; none is ever
  markup, and none reaches an id or a URL but the name and the ticket type (a file's name), whose characters
  the grammar restricts to the ones an id may hold.
  """

  use ForgeWeb, :html

  alias ForgeCore.Cron
  alias ForgeWeb.Format

  @doc "The Workflow view's address for a schedule: its type, and the schedule itself in the page."
  @spec path(Forge.Projects.Project.t(), %{ticket_type: String.t() | nil, name: String.t()}) ::
          String.t()
  def path(project, %{ticket_type: type, name: name}) do
    query = if type, do: [view: "workflow", type: type], else: [view: "workflow"]
    ~p"/projects/#{project.name}?#{query}" <> "#" <> anchor(type, name)
  end

  @doc """
  The element id of a schedule's row, which an alert's link ends in.

  **A hash of the type and the name, not the names**: a name may hold `.`, which an id cannot carry
  into the selector `JS.hide(to: "#" <> id)` the confirmation opens with (`schedule-a.b-on-ask` reads
  as an id and a class and matches nothing), and `b-c` of type `a` and `c` of type `a-b` would give
  one id (`schedule-a-b-c`). Twelve hex characters of the digest, which a person never reads.
  """
  @spec anchor(String.t() | nil, String.t()) :: String.t()
  def anchor(type, name) do
    digest = :crypto.hash(:sha256, "#{type}\0#{name}") |> Base.encode16(case: :lower)
    "schedule-" <> binary_part(digest, 0, 12)
  end

  @doc "The key a refusal is kept under, so it is drawn on the row that was pressed."
  @spec key(String.t() | nil, String.t()) :: String.t()
  def key(type, name), do: "#{type}/#{name}"

  @doc "A refusal in words, where it was pressed (`docs/design/ui.md` § Errors stay where you acted)."
  @spec explain(term()) :: String.t()
  def explain(:forbidden), do: "Only a project admin can switch a schedule on or off."

  def explain(:schedule_gone),
    do: "This schedule is no longer in its file, so it cannot be switched on."

  def explain(:schedule_unreadable),
    do: "Its file cannot be read right now, so it cannot be switched on."

  def explain(:already_on), do: "It is on already."
  def explain(:already_off), do: "It is off already."
  def explain(:no_alert), do: "There is nothing to dismiss."
  def explain(other), do: "It could not be done: #{inspect(other)}."

  attr :entry, :map, required: true, doc: "one element of `Forge.Schedules.declared/3`"
  attr :path, :string, required: true, doc: "the file it is declared in, for the hint"
  attr :project, :any, required: true
  attr :admin, :boolean, required: true, doc: "whether the reader may switch a schedule"
  attr :refusals, :map, default: %{}
  attr :now, :any, required: true

  def block(assigns) do
    ~H"""
    <div :if={show?(@entry)} id={"schedules-#{@entry.type || "workflow"}"} class="schedules">
      <.eyebrow>Schedules</.eyebrow>

      <p :if={@entry.schedules == [] and @entry.error == nil} class="project-hint schedules-hint">
        No schedules. A <span class="font-mono">schedules:</span>
        key in <span class="font-mono">{@path}</span>
        would admit a ticket of this type on a clock.
      </p>

      <p :if={@entry.error != nil and @entry.schedules != []} class="project-hint">
        Its workflow cannot be read, so a schedule that is on fails when it comes due and admits
        nothing until that is fixed:
      </p>

      <%!-- A refusal about a schedule the page no longer draws — it left the file between the page
            being drawn and the switch being pressed — is still said, where the schedules are. --%>
      <.error_note
        :for={{name, message} <- orphans(@refusals, @entry)}
        id={"#{anchor(@entry.type, name)}-refused"}
      >
        {name}: {message}
      </.error_note>

      <article
        :for={schedule <- @entry.schedules}
        id={anchor(@entry.type, schedule.name)}
        class={["schedule", schedule.on && "schedule--on"]}
      >
        <header class="schedule-head">
          <span class="schedule-name font-mono">{schedule.name}</span>
          <span class={["schedule-state", schedule.on && "schedule-state--on"]}>
            {if schedule.on, do: "on", else: "off"}
          </span>
        </header>

        <p :if={schedule.cron} class="schedule-cron">
          <span class="font-mono">{schedule.cron}</span>
          <span :if={words(schedule.cron)} class="schedule-words"> — {words(schedule.cron)}</span>
        </p>
        <p :if={schedule.title} class="schedule-title">{schedule.title}</p>

        <p :if={schedule.next_at} class="schedule-next">
          <span class="schedule-label">Next</span>
          <.local_time id={"#{anchor(@entry.type, schedule.name)}-next"} at={schedule.next_at} />
          <span class="schedule-ago">{Format.until_phrase(schedule.next_at, @now)}</span>
        </p>

        <p :if={schedule.on} class="schedule-by">
          Switched on by {schedule.row.enabled_by && schedule.row.enabled_by.email}, {Format.ago_phrase(
            schedule.row.enabled_at,
            @now
          )}. Each ticket is admitted in their name.
        </p>

        <p :if={schedule.row && schedule.row.last_ticket} class="schedule-last">
          <span class="schedule-label">Last ticket</span>
          <.link navigate={~p"/tickets/#{@project.name}/#{schedule.row.last_ticket.number}"}>
            #{schedule.row.last_ticket.number}
          </.link>
        </p>

        <.notice
          :if={schedule.row && schedule.row.problem}
          id={"#{anchor(@entry.type, schedule.name)}-problem"}
          tone="warning"
          title={problem_title(schedule.row.problem_kind)}
        >
          {schedule.row.problem}
          <span class="schedule-problem-at">
            {Format.ago_phrase(schedule.row.problem_at, @now)}
          </span>
        </.notice>

        <details :if={schedule.body} class="schedule-body">
          <summary>What it admits</summary>
          <pre class="schedule-body-text">{schedule.body}</pre>
        </details>

        <div :if={@admin} class="schedule-controls">
          <.confirm
            :if={not schedule.on}
            id={"#{anchor(@entry.type, schedule.name)}-on"}
            label="Switch on"
            act="Switch it on"
            tone="neutral"
            sentence={on_sentence(schedule)}
            phx-click="schedule:on"
            phx-value-type={@entry.type}
            phx-value-name={schedule.name}
          />
          <.button
            :if={schedule.on}
            id={"#{anchor(@entry.type, schedule.name)}-off"}
            type="button"
            variant="outline"
            size="sm"
            phx-click="schedule:off"
            phx-value-type={@entry.type}
            phx-value-name={schedule.name}
          >
            Switch off
          </.button>
        </div>

        <.error_note
          :if={@refusals[key(@entry.type, schedule.name)]}
          id={"#{anchor(@entry.type, schedule.name)}-refused"}
        >
          {@refusals[key(@entry.type, schedule.name)]}
        </.error_note>
      </article>
    </div>
    """
  end

  defp orphans(refusals, %{type: type, schedules: schedules}) do
    prefix = "#{type}/"
    drawn = MapSet.new(schedules, & &1.name)

    for {key, message} <- refusals,
        String.starts_with?(key, prefix),
        name = String.replace_prefix(key, prefix, ""),
        not MapSet.member?(drawn, name),
        do: {name, message}
  end

  defp problem_title(:switched_off), do: "Switched itself off"
  defp problem_title(_failed), do: "Could not admit its ticket"

  # The release type says nothing of schedules, since it may not have one. A type that has some, or
  # a hint to give, or schedules that are on though its file is broken, is drawn.
  defp show?(%{release: true, schedules: []}), do: false
  defp show?(%{error: error, schedules: []}) when error != nil, do: false
  defp show?(_entry), do: true

  # The sentence the confirmation says: what it admits, how often in words, and in whose name.
  defp on_sentence(schedule) do
    how = words(schedule.cron) || schedule.cron

    "Switch this on? It will admit “#{schedule.title}” #{how}, and each ticket is admitted " <>
      "in your name, until you or another admin switches it off."
  end

  defp words(nil), do: nil

  defp words(line) do
    case Cron.parse(line) do
      {:ok, cron} -> Cron.describe(cron)
      {:error, _} -> nil
    end
  end

  attr :id, :string, required: true
  attr :at, :any, required: true

  # The reader's own time. The server cannot know it, so the UTC text is what is drawn until the
  # browser's hook replaces it, and what stays where there is no script.
  defp local_time(assigns) do
    ~H"""
    <time id={@id} datetime={DateTime.to_iso8601(@at)} phx-hook=".LocalTime" class="schedule-time">
      {Calendar.strftime(@at, "%a %Y-%m-%d %H:%M")} UTC
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      // A time as the reader's own clock says it (`docs/design/ui.md` § Workflow). The server's
      // text is the UTC fallback, and a patch that redraws it is drawn over again.
      export default {
        mounted() { this.show() },
        updated() { this.show() },
        show() {
          const at = new Date(this.el.getAttribute("datetime"))
          if (isNaN(at)) return
          this.el.textContent = at.toLocaleString([], {
            weekday: "short", year: "numeric", month: "short", day: "numeric",
            hour: "2-digit", minute: "2-digit"
          })
        }
      }
    </script>
    """
  end
end
