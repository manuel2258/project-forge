defmodule Forge.Backlog do
  @moduledoc """
  The project's tickets, composed as files a job can read.

  `docs/design/ticket-proposals.md` § Reading the backlog is the standard. Every job gets one,
  with no grammar key, for the same reason every job may propose: an unread file costs nothing,
  and the scarce thing here is context rather than disk.

  Three rules it exists to keep:

  **Bodies only, never artifacts.** Another ticket's `plan.md` is reasoning at versions this job
  did not pin, and handing it over is how "artifacts are the contract" quietly stops being true:
  a job would be building on a document that is not in its manifest and cannot be approved on
  its behalf. A body says what the work is, which is all that duplicate suppression needs.

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

  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Projects.Project
  alias Forge.{Proposals, Repo}
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
    index = index(project, tickets, proposal_files, now)

    %{
      "index" => index,
      "tickets" => files,
      "proposals" => proposal_files,
      "hash" => hash([index | Enum.map(files ++ proposal_files, & &1["content"])])
    }
  end

  defp tickets(project_id) do
    Repo.all(
      from t in Ticket,
        where: t.project_id == ^project_id,
        order_by: [asc: t.number],
        select: %{
          number: t.number,
          title: t.title,
          body: t.body,
          state: t.state,
          status: t.status,
          branch: t.branch,
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

    """
    <!-- ticket #{ticket.number} · #{ticket.state} · #{ticket.status} · #{ticket.branch} -->

    """ <> text
  end

  defp index(%Project{} = project, tickets, proposal_files, now) do
    """
    # Tickets on #{project.name}

    Taken at #{DateTime.to_iso8601(now)}. This is a snapshot: it does not change while you work,
    so a ticket admitted after this moment is not here.

    One file per ticket in this folder, named after its number. Read a line here first and open
    the file only when the line looks relevant — the body is what the work is, and it is the
    only thing this folder holds. Another ticket's plan, report or changeset is not yours to
    read: it is pinned to a job that is not this one.

    #{table(tickets)}
    #{proposal_section(proposal_files)}
    """
  end

  defp table([]), do: "No tickets yet.\n"

  defp table(tickets) do
    rows =
      Enum.map_join(tickets, "\n", fn t ->
        "| #{t.number} | #{t.state} | #{t.status} | #{escape(t.title)} |"
      end)

    "| # | state | status | title |\n|---|---|---|---|\n" <> rows <> "\n"
  end

  defp proposal_section([]) do
    """

    ## Open proposals

    None. If you propose something, it appears here for every job that runs after you.
    """
  end

  defp proposal_section(proposal_files) do
    rows =
      Enum.map_join(proposal_files, "\n", fn p ->
        "| #{p["file"]} | #{escape(p["title"])} |"
      end)

    """

    ## Open proposals

    Written by a job and not yet admitted, so they are not tickets and no one is working on
    them. **Do not propose these again.** Files are in the `proposals/` folder beside this one.

    | file | title |
    |---|---|
    """ <> rows <> "\n"
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
