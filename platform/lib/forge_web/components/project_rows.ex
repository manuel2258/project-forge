defmodule ForgeWeb.ProjectRows do
  @moduledoc """
  The viewer's projects as the projects page draws them (`docs/design/ui.md` § The projects page,
  `11a`, `11e`): a list row each below 1024px and one table from it, from the rows
  `Forge.Projects.summaries/1` reads. Both are drawn and CSS shows one (`areas/project.css`), so a
  page never has to know the width it is on.

  The table is also what New project opens beside on a wide screen (`ForgeWeb.ProjectNewLive`),
  which is why it lives here rather than in `ForgeWeb.ProjectsLive`.

  **A row leads with what waits on you and what runs**; a project that can run nothing says so in
  danger in place of its latest line, because that is the state that looks fine everywhere else
  and takes no work.
  """

  use ForgeWeb, :html

  alias ForgeWeb.Format

  @doc "One list row per project, waiting first as `summaries/1` orders them."
  attr :rows, :list, required: true
  attr :now, :any, required: true

  def list(assigns) do
    ~H"""
    <div id="project-rows" class="project-rows">
      <.list_row
        :for={row <- @rows}
        id={"project-#{row.project.id}"}
        title={row.project.name}
        navigate={~p"/projects/#{row.project.name}"}
        edge={if row.waiting > 0, do: "accent"}
        latest={latest(row, @now)}
        latest_tone={if runs_nothing?(row), do: "danger"}
      >
        <:meta>
          <span class="project-open">{row.open_tickets} open</span>
          <span :if={row.running > 0} class="project-running">▸ {row.running} running</span>
          <span class="project-runs-on">{runs_on(row)}</span>
        </:meta>
        <:trailing>
          <span :if={row.waiting > 0} class="project-waiting">
            <.count_bubble value={"◆ #{row.waiting}"} tone="accent" />
          </span>
          <span class="ui-row-chevron" aria-hidden="true">›</span>
        </:trailing>
      </.list_row>
    </div>
    """
  end

  @doc "The same rows as one table, for a wide screen (`11e`): the phone's fields as columns."
  attr :rows, :list, required: true
  attr :now, :any, required: true

  def table(assigns) do
    ~H"""
    <div id="projects-table" class="projects-table" role="table" aria-label="Projects">
      <div class="projects-table-head" role="row">
        <span role="columnheader">project</span>
        <span role="columnheader">waiting</span>
        <span role="columnheader">running</span>
        <span role="columnheader">open</span>
        <span role="columnheader">runs on</span>
        <span role="columnheader">latest</span>
        <span aria-hidden="true"></span>
      </div>
      <.link
        :for={row <- @rows}
        id={"project-cells-#{row.project.id}"}
        navigate={~p"/projects/#{row.project.name}"}
        role="row"
        class={["projects-table-row", row.waiting > 0 && "projects-table-row--waiting"]}
      >
        <span role="cell" class="projects-table-name">{row.project.name}</span>
        <%!-- Every zero quiet, the same way: a dim waiting 0 beside full-ink running and open
              0s read as three different kinds of nothing (ux/c.md C17). --%>
        <span role="cell">
          <.count_bubble :if={row.waiting > 0} value={"◆ #{row.waiting}"} tone="accent" />
          <span :if={row.waiting == 0} class="projects-table-zero">0</span>
        </span>
        <span role="cell" class={[row.running > 0 && "project-running"]}>
          <span :if={row.running == 0} class="projects-table-zero">0</span>
          {if row.running > 0, do: "▸ #{row.running}"}
        </span>
        <span role="cell">
          <span :if={row.open_tickets == 0} class="projects-table-zero">0</span>
          {if row.open_tickets > 0, do: row.open_tickets}
        </span>
        <%!-- The column is narrow: the verdict, with the reason a hover away and in the row's
              accessible text. --%>
        <span
          :if={runs_nothing?(row)}
          role="cell"
          class="projects-table-runs-on project-danger"
          title={"#{missing(row)}, so nothing runs"}
          aria-label={"#{missing(row)}, so nothing runs"}
        >
          nothing can run
        </span>
        <span :if={not runs_nothing?(row)} role="cell" class="projects-table-runs-on">
          {runs_on(row)}
        </span>
        <span role="cell" class="projects-table-latest">{latest_line(row, @now)}</span>
        <span role="cell" class="ui-row-chevron" aria-hidden="true">›</span>
      </.link>
    </div>
    """
  end

  @doc """
  The subline under the page's title: how many projects, and how many of them wait on the viewer
  — the rows with a count, so it never disagrees with them. In `summary/2`'s words, which the
  title menu's Projects row uses too: the page once counted items (*4 waiting on you*) and the
  menu projects (*2 wait on you*), both under *4 projects* (UX re-check #9).
  """
  @spec subline([map()]) :: String.t()
  def subline(rows), do: summary(length(rows), Enum.count(rows, &(&1.waiting > 0)))

  @doc """
  How many projects, and how many of them wait on the viewer: `4 projects · 2 wait on you`. The
  items are the queue's to count, as decisions.
  """
  @spec summary(non_neg_integer(), non_neg_integer()) :: String.t()
  def summary(0, _waiting), do: "no projects"
  def summary(projects, 0), do: count(projects, "project")

  def summary(projects, waiting),
    do:
      "#{count(projects, "project")} · #{waiting} #{if waiting == 1, do: "waits", else: "wait"} on you"

  # What the project runs on. A template or a machine is shown when it has one; when it has
  # neither, both zeros are, since that is the fact. The credentials always are.
  defp runs_on(row) do
    [
      (row.templates > 0 or row.machines == 0) && count(row.templates, "template"),
      (row.machines > 0 or row.templates == 0) && count(row.machines, "machine"),
      count(row.credentials, "credential")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # The row's last line: what cannot run, in danger, or else the latest thing that happened.
  defp latest(row, now) do
    if runs_nothing?(row), do: "#{missing(row)}, so nothing runs", else: latest_line(row, now)
  end

  # On a row with a count, what has waited longest, and how many more: the count is amber because
  # of these, and a line about the latest-changed ticket hid them (ux/c.md C17). Else the most
  # recently changed open ticket, or — with none open — when the project last merged.
  defp latest_line(%{waiting: waiting, first_waiting: %{} = item}, now) when waiting > 0 do
    more = if waiting > 1, do: ", and #{waiting - 1} more", else: ""
    "#{waits(item)} · #{Format.ago_phrase(item.since, now)}#{more}"
  end

  defp latest_line(%{latest: %{status: :stuck} = ticket}, now),
    do:
      "##{ticket.number} is stuck in #{ticket.state} · #{Format.ago_phrase(ticket.updated_at, now)}"

  defp latest_line(%{latest: %{} = ticket}, now),
    do: "##{ticket.number} is #{ticket.state} · #{Format.ago_phrase(ticket.updated_at, now)}"

  defp latest_line(%{last_merge: nil}, _now), do: "nothing open"

  defp latest_line(%{last_merge: at}, now),
    do: "nothing running · last merge #{Format.ago_phrase(at, now)}"

  @doc "One waiting item (`Forge.Queue.item()`) in words, named by its ticket where it has one."
  @spec waits(map()) :: String.t()
  def waits(%{kind: :chat, ticket: nil}), do: "a chat waits for your reply"
  def waits(%{kind: :chat, ticket: t}), do: "##{t.number}'s chat waits for your reply"
  def waits(%{kind: :stuck, ticket: t}), do: "##{t.number} is stuck in #{t.state}"
  def waits(%{kind: :question, ticket: t}), do: "##{t.number} asks you a question"
  def waits(%{kind: :approval, ticket: t}), do: "##{t.number} waits for your approval"
  def waits(%{kind: :review, ticket: t}), do: "##{t.number} waits in #{t.state} for you"
  def waits(%{ticket: %{} = t}), do: "##{t.number} waits on you"
  def waits(_item), do: "something waits on you"

  @doc """
  Whether a project's row says it can run nothing. Nothing runs without a credential to pay for
  it, and nothing runs without somewhere to run: a template to make a machine from, or a permanent
  machine assigned to the project. New project's next steps read the same answer
  (`ForgeWeb.ProjectNewLive`).
  """
  @spec runs_nothing?(map()) :: boolean()
  def runs_nothing?(row), do: row.credentials == 0 or no_machine?(row)

  @doc "Whether a row has no template and no permanent machine: nowhere to run."
  @spec no_machine?(map()) :: boolean()
  def no_machine?(row), do: row.templates == 0 and row.machines == 0

  @doc "What a row that runs nothing lacks, in words: `no template or machine, and no credential`."
  @spec missing(map()) :: String.t()
  def missing(row) do
    case {no_machine?(row), row.credentials == 0} do
      {true, true} -> "no template or machine, and no credential"
      {true, false} -> "no template or machine"
      {false, true} -> "no credential"
    end
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
