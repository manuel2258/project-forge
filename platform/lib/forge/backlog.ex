defmodule Forge.Backlog do
  @moduledoc """
  The project's tickets, composed as files a job can read.

  `docs/design/ticket-proposals.md` § Reading the backlog is the standard. Every job gets one,
  with no grammar key, for the same reason every job may propose: an unread file costs nothing,
  and the scarce thing here is context rather than disk.

  Three rules it exists to keep:

  **Bodies only here; the artifacts are in the archive.** `tickets/` hands over a ticket's body and
  nothing else: another ticket's `plan.md` is reasoning at versions this job did not pin, so it is
  not an input anyone approved for this job. It can be read from `$FORGE_JOB/archive/`, which is
  live and says so (`docs/design/archive.md`). A body says what the work is, which is all that
  duplicate suppression needs.

  **Open proposals sit beside the tickets.** A proposal is a document rather than a ticket row,
  so an agent looking at the ticket list would not see one — and three jobs would each propose
  the same missing module. The obvious implementation, a query over `tickets`, gets this wrong
  silently, which is why it is stated here and tested.

  **It is a snapshot, not a pinned version.** Composed once when a job is assigned, with its
  hash recorded in the log so it is reproducible afterwards. It is the one thing a job is handed
  that is not an artifact version, because a generated index has no version to pin. The index
  says when it was taken, so a long job can tell that its view has aged.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Projects.Project
  alias Forge.{Proposals, Repo, Tickets}
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  @doc """
  The backlog for `project`, as the assignment carries it and the worker writes it.

  `%{"index" => text, "tickets" => [%{"file" =>, "content" =>}], "proposals" => [...],
  "hash" => sha}`. String keys, because this crosses the channel as JSON.
  """
  @spec compose(Project.t(), DateTime.t()) :: map()
  def compose(%Project{} = project, now \\ DateTime.utc_now(:second)) do
    tickets = tickets(project.id)
    bodies = bodies(project.id)
    proposals = proposals(project.id)

    files =
      Enum.map(tickets, fn ticket ->
        %{"file" => "#{ticket.number}.md", "content" => body(ticket, bodies)}
      end)

    proposal_files = proposal_files(proposals)
    index = index(project, tickets, proposal_files, types(project), now)

    %{
      "index" => index,
      "tickets" => files,
      "proposals" => proposal_files,
      "hash" => hash([index | Enum.map(files ++ proposal_files, & &1["content"])])
    }
  end

  defp tickets(project_id) do
    Repo.all(
      # A cancelled ticket is hidden everywhere a ticket is listed, and a job reading the backlog is
      # one more reader (`workflow-grammar-v1.md` § Cancelling a ticket).
      from t in Forge.Tickets.visible(Ticket),
        where: t.project_id == ^project_id,
        order_by: [asc: t.number],
        select: %{
          number: t.number,
          title: t.title,
          body: t.body,
          state: t.state,
          status: t.status,
          branch: t.branch,
          ticket_type: t.ticket_type,
          id: t.id
        }
    )
  end

  # The latest `ticket` document per ticket, in one query rather than one per ticket. A person
  # may have edited a ticket after admission, and the row's `body` is what was admitted rather
  # than what the ticket now says.
  defp bodies(project_id) do
    name = Workflow.ticket_artifact()

    latest =
      from v in Version,
        group_by: v.artifact_id,
        select: %{artifact_id: v.artifact_id, version: max(v.version)}

    Repo.all(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: t in Ticket,
        on: t.id == a.ticket_id,
        join: l in subquery(latest),
        on: l.artifact_id == v.artifact_id and l.version == v.version,
        where: t.project_id == ^project_id and a.name == ^name,
        select: {t.id, v.content}
    )
    |> Map.new()
  end

  defp proposals(project_id), do: Proposals.open(project_id)

  # One entry per open proposal: the name it is written under, its text, and its title for the
  # index — computed once here so the index and the folder can never disagree about either.
  #
  # The artifact's name is unique per *job*, not per project, so two jobs that both proposed
  # `follow-up.md` carry one name into one folder: the second write wins, while the index lists
  # both and tells the agent not to propose either again. That is the one promise this folder
  # exists to keep, so a colliding name is qualified by the job that wrote it — and only when it
  # collides, because the agent's own filename is the only word it gets to say about what a
  # proposal is for.
  defp proposal_files(proposals) do
    counts = Enum.frequencies_by(proposals, & &1.artifact.name)

    Enum.map(proposals, fn proposal ->
      name = proposal.artifact.name

      qualified =
        if counts[name] > 1, do: "#{String.slice(proposal.job.id, 0, 8)}-#{name}", else: name

      %{
        "file" => qualified,
        "content" => proposal.version.content || "",
        "title" => title_of(proposal.version)
      }
    end)
  end

  defp body(ticket, bodies) do
    text = Map.get(bodies, ticket.id) || "# #{ticket.title}\n\n#{ticket.body}"

    fields =
      Enum.reject([ticket.ticket_type, ticket.state, ticket.status, ticket.branch], &is_nil/1)

    """
    <!-- ticket #{ticket.number} · #{Enum.join(fields, " · ")} -->

    """ <> text
  end

  # The project's ticket types as the default branch declares them now, so a proposal can suggest
  # one (`docs/design/ticket-types.md` § What a job is told). Read from the repository on every
  # composition; a project with the single file, or whose repository cannot say, has none here.
  #
  # **A fault in reading them costs this section, never the job.** The backlog is composed inside
  # every assignment, so anything that raises here failed every job of the project — chats
  # included — over a file most of them never read: a library with an empty `commands:` did, until
  # the parser learned to read one. The rescue is the defence against the next such case and an
  # equivalent mutant today, since no input the parser is known to raise on remains to test it
  # with; removing it changes nothing a test can see until one does. `single: false` is one too:
  # the match below drops a single file's entry either way, and the option only spares its parse.
  defp types(project) do
    case Tickets.types(project, single: false) do
      {:ok, %{form: :types, types: types}} -> Enum.reject(types, & &1.release)
      _single_or_unreadable -> []
    end
  rescue
    exception ->
      Logger.error(
        "could not read the ticket types of #{project.name} for a backlog: " <>
          Exception.message(exception)
      )

      []
  end

  defp index(%Project{} = project, tickets, proposal_files, types, now) do
    """
    # Tickets on #{project.name}

    Taken at #{DateTime.to_iso8601(now)}. This is a snapshot: it does not change while you work,
    so a ticket admitted after this moment is not here.

    One file per ticket in this folder, named after its number. Read a line here first and open
    the file only when the line looks relevant — the body is what the work is, and it is the
    only thing this folder holds. Another ticket's plan, report or changeset is not yours to
    read: it is pinned to a job that is not this one.

    #{table(tickets)}
    #{types_section(types)}#{proposal_section(proposal_files)}
    """
  end

  defp table([]), do: "No tickets yet.\n"

  # A type column only where some ticket has a type: on a project with the single workflow file
  # it would be a column of dashes in every job's context.
  defp table(tickets) do
    typed? = Enum.any?(tickets, & &1.ticket_type)

    columns =
      if typed?,
        do: ["#", "type", "state", "status", "title"],
        else: ["#", "state", "status", "title"]

    rows =
      Enum.map(tickets, fn t ->
        type = if typed?, do: [t.ticket_type || "—"], else: []
        [t.number | type] ++ [t.state, t.status, escape(t.title)]
      end)

    markdown_table(columns, rows)
  end

  # Every table in the index: a header, its rule, and a row per entry. One builder, so the three
  # tables cannot drift into three dialects of the same markdown.
  defp markdown_table(columns, rows) do
    rule = "|" <> String.duplicate("---|", length(columns))
    Enum.join([cells(columns), rule | Enum.map(rows, &cells/1)], "\n") <> "\n"
  end

  defp cells(row), do: "| " <> Enum.join(row, " | ") <> " |"

  defp types_section([]), do: ""

  defp types_section(types) do
    rows =
      Enum.map(types, fn
        %{name: name, workflow: {:ok, workflow}} ->
          [name, workflow.initial, escape(workflow.description)]

        %{name: name} ->
          [name, "—", "(its workflow does not parse)"]
      end)

    """

    ## Ticket types

    Each type is a different workflow. A proposal may suggest one as `type:` in its front
    matter; a person confirms it when they accept.

    """ <> markdown_table(["type", "starts in", "description"], rows)
  end

  defp proposal_section([]) do
    """

    ## Open proposals

    None. If you propose something, it appears here for every job that runs after you.
    """
  end

  defp proposal_section(proposal_files) do
    rows = Enum.map(proposal_files, &[&1["file"], escape(&1["title"])])

    """

    ## Open proposals

    Written by a job and not yet admitted, so they are not tickets and no one is working on
    them. **Do not propose these again.** Files are in the `proposals/` folder beside this one.

    """ <> markdown_table(["file", "title"], rows)
  end

  # The title is the proposal's H1, and a proposal that no longer parses still has to appear:
  # it is open, and an agent that cannot see it proposes the same thing again. Hence the
  # fallback rather than a filter.
  defp title_of(%Version{content: content}) when is_binary(content) do
    case ForgeCore.Proposal.parse(content) do
      {:ok, proposal} -> proposal.title
      {:error, _errors} -> "(unreadable)"
    end
  end

  defp title_of(%Version{}), do: "(no content)"

  defp escape(nil), do: ""
  defp escape(text), do: text |> String.replace("|", "\\|") |> String.replace("\n", " ")

  defp hash(parts) do
    parts
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
