defmodule ForgeWeb.ProjectLive do
  @moduledoc """
  One project (`docs/design/ui.md` § The project page, `7a`–`7h`, `21c`, `21d`): its views
  **Tickets · Merge · Chats · Workflow · Proposals**, its details dropped from its name, and
  `+ New` — a ticket, a chat, and for a project admin the release.

  **There is no board.** Tickets says what each open ticket is doing; the Workflow view's map puts
  them on their states.

  **One markup, three arrangements.** Every view's section is drawn on every render, and CSS shows
  the one in `?view=` below 768px; from 768 they stack with the facts in a rail (`7g`), and from
  1440 the map goes on top, the tickets left and the rest right (`7h`). The page never has to know
  the width it is on — the same rule the projects page follows.

  The workflow is shown and never edited: it lives in the project's repository, and what is shown
  is the repository's current one, which the *next* ticket will pin.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components,
    only: [copyable: 1, merge_queue_place: 1, merge_queue_doing: 1]

  alias Forge.{
    Changelog,
    Conversations,
    Events,
    ForgeRelease,
    Git,
    MergeQueue,
    Operator,
    Projects,
    Proposals,
    Queue,
    ReleaseTickets,
    Tickets
  }

  alias Forge.Git.Url
  alias Forge.Tickets.{Doing, Ticket}
  alias ForgeWeb.{Format, ProjectTickets, ProposalsView, ReleaseComponents, WorkflowMap}
  alias ForgeWeb.Operator.{Actions, Admission, Drafts}

  @views ~w(tickets merge chats workflow proposals)

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)

    if connected?(socket) do
      Events.subscribe()
      Events.subscribe_chats()
    end

    {:ok,
     socket
     |> assign(
       project_id: project.id,
       page_title: project.name,
       drafts: Drafts.init(),
       refusal: nil,
       filter: "open",
       type: nil,
       release_error: nil,
       chat_error: nil,
       # The Proposals view's own state (`docs/design/ui.md` § Proposals): which list, whether
       # selecting and what, and what was skipped this visit — Skip writes nothing.
       plist: "open",
       selecting: false,
       selected: MapSet.new(),
       skipped: [],
       proposal_error: nil,
       bulk_error: nil,
       history_error: nil,
       # Whether this page draws the release block. `Operator.start_release/3` refuses without it,
       # which is the half that matters.
       manage: Forge.Access.can?(scope, :manage)
     )
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] in @views, do: params["view"], else: "tickets"
    state = if is_binary(params["state"]) and params["state"] != "", do: params["state"]

    read = if is_binary(params["read"]) and params["read"] != "", do: params["read"]

    {:noreply,
     assign(socket,
       view: view,
       # Only a view the address names, not the default: the wide page then opens on it.
       view_given: params["view"] in @views and params["view"] != "tickets",
       state: state,
       reading: read,
       new: Map.has_key?(params, "new")
     )}
  end

  defp load(%{assigns: %{project_id: id}} = socket) do
    project = Projects.get!(id)
    all = Tickets.all(project)
    {open, closed} = Enum.split_with(all, &(&1.status in Ticket.open_statuses()))
    queue = MergeQueue.with_places(project.id)
    # The default branch's tip, resolved once: the workflow block and the forge release line are
    # drawn from this one commit, so they are redrawn together and never disagree about it.
    #
    # `Tickets.types/2` itself is tested to read at the sha it is given. Passing `at: tip` here
    # rather than letting it resolve the branch again is an equivalent mutant at *this* call: both
    # read the same commit unless the branch moves between the two reads, which a test cannot
    # arrange. The `at:` makes the agreement hold by construction, not by any visible effect.
    tip = default_tip(project)
    current = if tip, do: Tickets.types(project, at: tip), else: Tickets.types(project)
    places = Map.new(queue, fn {entry, place} -> {entry.ticket_id, place} end)
    now = DateTime.utc_now()
    ids = Enum.map(open, & &1.id)

    rows =
      ProjectTickets.rows(open, %{
        items:
          Enum.filter(Queue.items(socket.assigns.current_scope.user), &(&1.project.id == id)),
        live: Doing.live(ids),
        said: Doing.said(ids),
        places: places,
        paused: Forge.Spend.paused?(),
        now: now
      })

    assign(socket,
      project: project,
      rows: rows,
      history: Enum.sort_by(closed, & &1.updated_at, {:desc, DateTime}),
      # The merge queue in order. Replaced only by a read that succeeded: `load/1` raises on a
      # failure, so the last known order stays.
      queue: queue,
      merged: Doing.merged(project.id, 5),
      queueing: queueing_edges(current),
      # The repository's current workflow, which is what the *next* ticket will pin — not the
      # one each open ticket follows, which it pinned at admission.
      current: current,
      forge_release: forge_release(project, tip),
      release: release_block(socket, current, project),
      latest_release: Forge.ReleaseRecords.latest(project),
      clone_url: Url.for(project),
      mirrors: Projects.list_mirrors(project),
      # Every ticket's, a cancelled one's too: cancelling hides a ticket, it does not unspend it.
      spent: all |> Enum.map(& &1.usage) |> Enum.sum(),
      listed: Enum.count(all, &(&1.status != :cancelled)),
      now: now
    )
    |> load_proposals(project, all)
    |> load_chats()
  end

  defp default_tip(project) do
    case Git.resolve(Projects.repo_path(project), project.default_branch) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  # What the repository records as its forge release at `tip`, and how that compares with the node
  # (`docs/design/changelog.md`). With no tip there is no repository content to read: the line says
  # not recorded and no notice is drawn, since the page's own "cannot take a ticket" block speaks
  # for a repository with no default branch.
  defp forge_release(_project, nil), do: :empty

  defp forge_release(project, tip),
    do: project |> Projects.repo_path() |> ForgeRelease.read(tip) |> ForgeRelease.status()

  defp forge_release_line(status) when status in [:not_recorded, :empty], do: "not recorded"
  defp forge_release_line(:current), do: Changelog.running()
  defp forge_release_line({:behind, version}), do: version
  defp forge_release_line({:newer, version}), do: version
  defp forge_release_line({:not_release, _quote}), do: "not a release"

  attr :status, :any, required: true
  attr :project, :any, required: true

  # A warning about the forge release the project records (`docs/design/ui.md` § The project
  # page), a `warning` notice at the head of the page, so it is above every view on a phone. Every
  # sentence says "forge", so none is read as the project's own releases. What the file holds
  # reaches the page as escaped text only, and the link's request names the release the node runs
  # and nothing from the file.
  defp forge_release_notice(%{status: status} = assigns) when status in [:current, :empty],
    do: ~H""

  defp forge_release_notice(assigns) do
    assigns = assign(assigns, :running, Changelog.running())

    ~H"""
    <.notice id="forge-release-notice" tone="warning" title={notice_title(@status)}>
      <p class="project-notice-text">
        <%= case @status do %>
          <% {:behind, version} -> %>
            Written for forge {version}. This node runs forge {@running}.
          <% :not_recorded -> %>
            This project records no forge release, so it counts as forge {Changelog.baseline()}.
            This node runs forge {@running}.
          <% {:newer, version} -> %>
            This project was written for forge {version}, which is newer than the forge {@running} this node runs. Features it uses may not work here.
          <% {:not_release, :too_large} -> %>
            <code>{ForgeRelease.path()}</code>
            is larger than {ForgeRelease.max_bytes()} bytes, so it does not name a forge release.
          <% {:not_release, text} -> %>
            <code>{ForgeRelease.path()}</code>
            does not name a forge release. It holds <code id="forge-release-quote">{text}</code>.
        <% end %>
      </p>
      <.link
        :if={upgrade?(@status)}
        id="forge-upgrade-link"
        navigate={~p"/chats/new?#{[project: @project.name, text: upgrade_request(@running)]}"}
        class="project-link project-notice-link"
      >
        Bring this project up to forge {@running} in a new chat ›
      </.link>
    </.notice>
    """
  end

  defp notice_title({:behind, _version}), do: "Behind this node's forge"
  defp notice_title(:not_recorded), do: "No forge release recorded"
  defp notice_title({:newer, _version}), do: "Newer than this node's forge"
  defp notice_title({:not_release, _quote}), do: "Not a forge release"

  defp upgrade?(:not_recorded), do: true
  defp upgrade?({:behind, _version}), do: true
  defp upgrade?(_status), do: false

  # Written here and never from the file: it names the release the node runs, and the agent reads
  # the project's recorded release itself (`docs/design/changelog.md` § How an upgrade goes).
  defp upgrade_request(running), do: "Bring this project up to forge #{running}."

  # The open proposals by the job that wrote them, and the decided ones for History. Every
  # ticket's number, a cancelled one's too: its proposals are still its.
  defp load_proposals(socket, project, tickets) do
    open = Proposals.open(project.id)
    decided = Proposals.decided(project.id)
    by_id = Map.new(tickets, &{&1.id, &1})

    openings =
      (open ++ decided)
      |> Enum.filter(&(&1.job.kind == :chat))
      |> Enum.map(& &1.job.id)
      |> Enum.uniq()
      |> Proposals.openings()

    groups = ProposalsView.groups(open, by_id, openings)
    open_ids = MapSet.new(ProposalsView.order(groups))

    assign(socket,
      groups: groups,
      proposals: Enum.flat_map(groups, & &1.items),
      decided: Enum.map(decided, &ProposalsView.entry(&1, by_id, openings)),
      # A proposal decided elsewhere is no longer selectable here.
      selected: MapSet.intersection(socket.assigns.selected, open_ids)
    )
  end

  # Apart from `load/1` because a conversation being said in is far more frequent than anything
  # else on this page, and reading the repository to redraw one list would be a waste.
  defp load_chats(%{assigns: %{project_id: id}} = socket) do
    chats = Conversations.summaries(project_id: id)
    ids = Enum.map(chats, & &1.chat.id)

    assign(socket,
      chats: chats,
      proposed: Proposals.counts_by_job(ids),
      # What each chat was opened with, which is what tells one from another: its last line does
      # not, and two chats that ended on the same words could not be told apart.
      openings: Proposals.openings(ids),
      now: DateTime.utc_now()
    )
  end

  # The edges the repository's current workflows queue on, for the empty queue to say what would
  # fill it.
  defp queueing_edges(current) do
    for type <- current_types(current),
        {:ok, workflow} <- [type.workflow],
        transition <- workflow.transitions,
        ForgeCore.Workflow.Transition.queues?(transition),
        uniq: true,
        do: "#{transition.from} → #{transition.to}"
  end

  # A merge queue shows this many rows and folds the rest behind "N more".
  @queue_rows 8

  # What the release block draws, for a project admin and nobody else: one of `{:open, ticket}`,
  # `{:ready, entry}`, `{:broken, entry}`, `:none` and `{:several, paths}`. An open release wins
  # over the rest, because starting another is what it is there to prevent.
  defp release_block(%{assigns: %{manage: false}}, _current, _project), do: nil

  defp release_block(_socket, current, project) do
    case ReleaseTickets.open(project) do
      nil -> release_status(ReleaseTickets.status(current))
      ticket -> {:open, ticket}
    end
  end

  defp release_status({:ok, %{workflow: {:ok, _workflow}} = entry}), do: {:ready, entry}
  defp release_status({:ok, entry}), do: {:broken, entry}
  defp release_status({:error, {:several_release_workflows, paths}}), do: {:several, paths}
  defp release_status({:error, :no_release_workflow}), do: :none

  # -- events -------------------------------------------------------------------------------

  @impl true
  # Both answers are the same answer here — the draft is held, or the payload named no form and
  # there was nothing to hold — and neither needs a reload. The `:unknown` arm is answered
  # rather than matched on purpose: the payload is off the wire, and a crafted one naming no
  # form would otherwise take the page down with a match error.
  def handle_event("draft:change", params, socket) do
    case Drafts.handle("draft:change", params, socket) do
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  def handle_event("take-out", params, socket) do
    case Actions.handle("take-out", params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      :unknown -> {:noreply, socket}
    end
  end

  # The open tickets narrowed to what waits on you or what runs. The page's own; nothing written.
  def handle_event("tickets:filter", %{"value" => value}, socket)
      when value in ~w(open waiting running),
      do: {:noreply, assign(socket, filter: value)}

  def handle_event("tickets:filter", _params, socket), do: {:noreply, socket}

  # Which type's workflow the Workflow view shows. The page's own; an unknown name shows none.
  def handle_event("workflow:type", %{"value" => value}, socket) when is_binary(value),
    do: {:noreply, assign(socket, type: value)}

  def handle_event("workflow:type", _params, socket), do: {:noreply, socket}

  # A conversation started in place, the project fixed (`7c`). `Operator.open_chat/4` checks the
  # person is a member, which this page's mount already did — the check is the operation's.
  def handle_event("chat:start", params, socket) do
    text = if is_binary(params["text"]), do: String.trim(params["text"]), else: ""

    with false <- text == "",
         {:ok, chat} <-
           Operator.open_chat(socket.assigns.project, socket.assigns.current_scope.user, text) do
      {:noreply,
       socket
       |> Drafts.forget("chat")
       |> push_navigate(to: ~p"/chats/#{chat.id}")}
    else
      true ->
        {:noreply, assign(socket, chat_error: "Say what the chat is about first.")}

      # Only a refusal of membership reaches here, which the mount has already made: an
      # equivalent mutant today, said in a sentence rather than as `inspect/1` all the same.
      {:error, _reason} ->
        {:noreply, assign(socket, chat_error: "The chat could not be started here.")}
    end
  end

  # The only door to a release (`Forge.Operator.start_release/3` guards it), so a member pushing
  # this event is refused whatever the page drew. The note comes off the wire and is made a
  # string here rather than trusted to be one. A refusal is said inside the sheet.
  def handle_event("release:start", params, socket) do
    note = if is_binary(params["note"]), do: params["note"], else: ""
    project = socket.assigns.project

    case Operator.start_release(project, socket.assigns.current_scope.user, note) do
      {:ok, ticket} ->
        {:noreply,
         socket
         # An equivalent mutant: the page is left for the ticket's own, and the draft goes with
         # this process. It is dropped here so that the assign never outlives the send it was for.
         |> Drafts.forget("release")
         |> ForgeWeb.Toast.put("Release started as ticket ##{ticket.number}")
         |> push_navigate(to: ~p"/tickets/#{project.name}/#{ticket.number}")}

      {:error, :forbidden} ->
        {:noreply, assign(socket, release_error: "Only a project admin can start a release.")}

      # The page is reloaded, so it shows what is true now — a flag that has moved is not a ticket
      # event, and nothing else would tell this page. The draft stays, and where the reload leaves
      # no box the block shows the note as unsent text.
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(release_error: "Not started: " <> Admission.explain(reason) <> ".")
         |> load()}
    end
  end

  def handle_event(
        "decide_proposal",
        %{"version_id" => id, "decision" => decision} = params,
        socket
      ) do
    user = socket.assigns.current_scope.user
    comment = params["comment"]

    result =
      case decision do
        "accepted" -> Operator.accept_proposal(id, user, comment, params["ticket_type"])
        "declined" -> Operator.decline_proposal(id, user, comment)
      end

    # Decided, so the draft goes and the reader moves on; refused, so what was typed stays to be
    # sent again, and the refusal is said in the reader.
    next = next_after(socket, id)

    case result do
      {:ok, %Ticket{number: number}} ->
        {:noreply,
         socket |> decided(params, "Admitted as ticket ##{number}") |> load() |> read(next)}

      {:ok, _decision} ->
        {:noreply, socket |> decided(params, "Declined") |> load() |> read(next)}

      {:error, reason} ->
        {:noreply, socket |> assign(proposal_error: explain(reason)) |> load()}
    end
  end

  # Which list the Proposals view shows: the open ones, or what became of the decided ones.
  def handle_event("proposals:list", %{"value" => value}, socket)
      when value in ~w(open admitted declined),
      do: {:noreply, assign(socket, plist: value)}

  def handle_event("proposals:list", _params, socket), do: {:noreply, socket}

  # Skip is the page's and writes nothing: the proposal goes to the end of this visit's pass and
  # the reader moves to the next one.
  def handle_event("proposals:skip", %{"id" => id}, socket) when is_binary(id) do
    next = next_after(socket, id)
    skipped = List.delete(socket.assigns.skipped, id) ++ [id]
    {:noreply, socket |> assign(skipped: skipped, proposal_error: nil) |> read(next)}
  end

  def handle_event("proposals:selecting", %{"value" => "on"}, socket),
    do: {:noreply, assign(socket, selecting: true)}

  def handle_event("proposals:selecting", _params, socket),
    do: {:noreply, assign(socket, selecting: false, selected: MapSet.new(), bulk_error: nil)}

  # The boxes as the form holds them. Only ids of open proposals on this page are kept, so a
  # crafted payload selects nothing it could not see.
  def handle_event("proposals:select", params, socket) do
    open = MapSet.new(ProposalsView.order(socket.assigns.groups))

    picked =
      params |> Map.get("ids", []) |> List.wrap() |> MapSet.new() |> MapSet.intersection(open)

    {:noreply, assign(socket, selected: picked)}
  end

  # A group's box: everything from that source, or — when all of it is picked — none of it.
  def handle_event("proposals:group", %{"job" => job_id}, socket) do
    case Enum.find(socket.assigns.groups, &(&1.job_id == job_id)) do
      nil ->
        {:noreply, socket}

      group ->
        ids = MapSet.new(group.items, & &1.version_id)
        selected = socket.assigns.selected

        selected =
          if MapSet.subset?(ids, selected),
            do: MapSet.difference(selected, ids),
            else: MapSet.union(selected, ids)

        {:noreply, assign(socket, selected: selected)}
    end
  end

  # The bulk bar's two verbs. Declining is one operation, refused whole; admitting is one
  # admission per proposal, each its own ticket, and what was refused is said in the bar.
  def handle_event("proposals:bulk", %{"bulk" => "decline"} = params, socket) do
    reason = if is_binary(params["reason"]) and params["reason"] != "", do: params["reason"]
    ids = MapSet.to_list(socket.assigns.selected)

    case Operator.decline_proposals(ids, socket.assigns.current_scope.user, reason) do
      {:ok, decisions} ->
        {:noreply, socket |> bulk_done("Declined #{length(decisions)}") |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(bulk_error: "None declined: " <> explain(reason)) |> load()}
    end
  end

  def handle_event("proposals:bulk", %{"bulk" => "admit"} = params, socket) do
    ids = MapSet.to_list(socket.assigns.selected)
    type = if is_binary(params["ticket_type"]), do: params["ticket_type"]
    user = socket.assigns.current_scope.user
    results = Enum.map(ids, &Operator.accept_proposal(&1, user, nil, type))
    admitted = Enum.count(results, &match?({:ok, _}, &1))
    refused = for {:error, reason} <- results, uniq: true, do: explain(reason)

    socket =
      if refused == [],
        do: bulk_done(socket, "Admitted #{admitted}"),
        else:
          assign(socket,
            bulk_error: "Admitted #{admitted} of #{length(ids)}. " <> Enum.join(refused, " ")
          )

    {:noreply, load(socket)}
  end

  def handle_event("proposals:bulk", _params, socket), do: {:noreply, socket}

  # Reopening a declined proposal (`docs/design/ticket-proposals.md` § Deciding):
  # `Operator.reopen_proposal/2` checks who may and that it is a declined one.
  def handle_event("proposal:reopen", %{"id" => id}, socket) when is_binary(id) do
    case Operator.reopen_proposal(id, socket.assigns.current_scope.user) do
      {:ok, _version} ->
        {:noreply,
         socket |> assign(history_error: nil) |> ForgeWeb.Toast.put("Reopened") |> load()}

      {:error, :not_declined} ->
        {:noreply,
         socket
         |> assign(history_error: "Only a declined proposal can be reopened, once.")
         |> load()}

      {:error, _not_found} ->
        {:noreply,
         socket |> assign(history_error: "That proposal is not here any more.") |> load()}
    end
  end

  # A question to the chat a proposal came from (`8b`), so a vague one can be sharpened before it
  # becomes a ticket. `Operator.send_chat/4` checks membership; a proposal a ticket's job wrote has
  # no chat to ask, and is refused here as well as drawn no composer.
  def handle_event("proposal:ask", params, socket) do
    text = if is_binary(params["text"]), do: String.trim(params["text"]), else: ""

    with false <- text == "",
         %{job: %{kind: :chat} = chat} <- Proposals.get(to_string(params["version_id"])),
         true <- chat.project_id == socket.assigns.project_id,
         {:ok, _sent} <- Operator.send_chat(chat, socket.assigns.current_scope.user, text) do
      {:noreply,
       socket
       |> Drafts.forget("ask")
       |> assign(proposal_error: nil)
       |> ForgeWeb.Toast.put("Asked the chat", "Its answer is in the conversation.")}
    else
      true ->
        {:noreply, assign(socket, proposal_error: "Write the question first.")}

      _no_chat_or_refused ->
        {:noreply, assign(socket, proposal_error: "The chat could not be asked.")}
    end
  end

  defp bulk_done(socket, message) do
    socket
    |> Drafts.forget("bulk")
    |> assign(selecting: false, selected: MapSet.new(), bulk_error: nil)
    |> ForgeWeb.Toast.put(message)
  end

  # The open proposals in the order a pass reads them: as the list draws them, what was skipped
  # this visit moved to the end.
  defp ordered(assigns) do
    order = ProposalsView.order(assigns.groups)
    skipped = Enum.filter(assigns.skipped, &(&1 in order))
    (order -- skipped) ++ skipped
  end

  # The proposal after `id` in the pass, wrapping round, or nil when it was the last one.
  defp next_after(socket, id) do
    order = ordered(socket.assigns)

    case Enum.find_index(order, &(&1 == id)) do
      nil -> List.first(order -- [id])
      i -> order |> Enum.drop(i + 1) |> Kernel.++(Enum.take(order, i)) |> List.first()
    end
  end

  # The reader on `id`, by the page's own address; nil leaves the reader for the list.
  defp read(socket, id) do
    query = if id, do: [view: "proposals", read: id], else: [view: "proposals"]

    socket
    |> assign(proposal_error: nil)
    |> push_patch(to: ~p"/projects/#{socket.assigns.project.name}?#{query}")
  end

  # Forgetting here is an equivalent mutant, kept for the assign rather than for the page: a
  # decided proposal is not in `Proposals.open/1` any more, so `propose-<version_id>` is never
  # drawn again and keeping it changes nothing anybody could see.
  defp decided(socket, params, message),
    do: socket |> Drafts.forget(params["draft"]) |> ForgeWeb.Toast.put(message)

  defp explain(:already_decided), do: "Someone has already decided that one."
  defp explain(:not_found), do: "One of them is not yours to decide."
  defp explain({:invalid_proposal, errors}), do: ForgeCore.Error.format(errors)

  # Anything else is why the project could not admit it, in the sentence the ticket form uses.
  defp explain(reason), do: "Not admitted: " <> Admission.explain(reason) <> "."

  # Only this project's tickets. `load/1` shells out to git several times — the workflow, the
  # mirror — so reloading on every ticket in the system would spend that on events belonging to
  # other projects.
  #
  # The project is read from the row rather than matched against the tickets already loaded: a
  # ticket admitted *since* this page mounted is exactly the one that has to appear, and it is
  # not in that list. One indexed read is far less than what it saves.
  # A project chat's changes are `chat_changed`, with no ticket, and are not `ticket_changed`'s.
  @impl true
  def handle_info({:ticket_changed, nil}, socket), do: {:noreply, socket}

  # Only this project's chats redraw the list, matched in the head before anything is read.
  def handle_info(
        {:chat_changed, _id, project_id, _ticket_id},
        %{assigns: %{project_id: project_id}} = socket
      ),
      do: {:noreply, load_chats(socket)}

  def handle_info({:chat_changed, _id, _other, _ticket_id}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, socket) do
    project_id = socket.assigns.project.id

    case Forge.Repo.get(Ticket, id) do
      %{project_id: ^project_id} -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  # -- what the render reads ----------------------------------------------------------------

  defp current_types({:ok, %{types: types}}), do: types
  defp current_types(_error), do: []

  # The type the Workflow view shows: the one chosen, else the ordinary one with the most open
  # tickets — the first alphabetically left a map of two dots on a project with six tickets of
  # another type — else the first ordinary one, else the first.
  defp shown_type(current, chosen, rows) do
    types = current_types(current)
    open = open_by_type(rows)

    Enum.find(types, &(&1.name == chosen)) ||
      types
      |> Enum.reject(& &1.release)
      |> Enum.max_by(&Map.get(open, &1.name, 0), fn -> nil end) ||
      List.first(types)
  end

  defp open_by_type(rows), do: Enum.frequencies_by(rows, & &1.ticket.ticket_type)

  # The types an Accept is asked to choose between, each marked when its workflow does not parse:
  # only when there is more than one.
  defp choosable(current) do
    case current |> ReleaseTickets.ordinary() |> current_types() do
      [_, _ | _] = types ->
        Enum.map(types, &%{name: &1.name, parses: Admission.ready?(&1.workflow)})

      _none_or_one ->
        []
    end
  end

  defp not_types({:ok, %{not_types: not_types}}), do: not_types
  defp not_types(_error), do: []

  defp description(%{workflow: {:ok, workflow}}), do: workflow.description
  defp description(_type), do: nil

  defp type_id(type), do: "type-#{type.name || "workflow"}"
  defp workflow_id(type), do: if(type.name, do: "workflow-#{type.name}", else: "workflow")

  # The rows the filter and a state chosen on the map leave.
  defp filtered(rows, filter, state) do
    Enum.filter(rows, &(kept?(&1, filter) and (is_nil(state) or &1.ticket.state == state)))
  end

  defp kept?(row, "waiting"), do: row.waiting
  defp kept?(row, "running"), do: row.running
  defp kept?(_row, _open), do: true

  defp waiting_count(rows), do: Enum.count(rows, & &1.waiting)
  # A job running now: a ticket queued to merge or waiting for a machine is not running, though
  # the map draws it with the running ones.
  defp running_count(rows), do: Enum.count(rows, & &1.running)

  defp subline(rows) do
    case waiting_count(rows) do
      0 -> "#{length(rows)} open"
      n -> "#{length(rows)} open · #{n} waiting on you"
    end
  end

  defp views(assigns) do
    strip(
      assigns.project,
      %{
        "tickets" => length(assigns.rows),
        "merge" => length(assigns.queue),
        "chats" => length(assigns.chats),
        "proposals" => length(assigns.proposals)
      },
      :patch
    )
  end

  @doc """
  The project's views (`docs/design/ui.md` § The bottom strip: a project, its repository and its
  settings), each leading to this page on that view — by patch from this page, by navigation from
  the repository, a commit and the settings. `counts` holds the figures this page has read, by
  view; a page that has not read them passes none and draws no count, rather than a zero that
  is not true.
  """
  @spec strip(map(), %{String.t() => non_neg_integer()}, :patch | :navigate) :: [map()]
  def strip(project, counts, link) do
    for {key, label} <- [
          {"tickets", "Tickets"},
          {"merge", "Merge"},
          {"chats", "Chats"},
          {"workflow", "Workflow"},
          {"proposals", "Proposals"}
        ] do
      Map.put(
        %{key: key, label: label, count: counts[key]},
        link,
        ~p"/projects/#{project.name}?#{[view: key]}"
      )
    end
  end

  # A fact row. One mirror having stopped working is worth a word here because this is the page
  # somebody actually opens; `docs/design/git-hosting.md` § What the mirrors say about themselves.
  defp mirror_summary([]), do: "none"

  defp mirror_summary(mirrors) do
    Enum.map_join(mirrors, ", ", fn
      %{name: name, last_status: "failed"} -> "#{name} (failing)"
      %{name: name} -> name
    end)
  end

  defp mirror_failing?(mirrors), do: Enum.any?(mirrors, &(&1.last_status == "failed"))

  defp queue_rows, do: @queue_rows

  defp proposals_on(proposed, chat_id) do
    case Map.get(proposed, chat_id, 0) do
      0 -> nil
      1 -> "1 proposal"
      n -> "#{n} proposals"
    end
  end

  # The last line beneath a row named by its opening, unless it is the opening itself: a chat
  # nobody has answered yet would say the same words twice.
  defp chat_latest(opening, said) do
    case {opening_title(opening), said} do
      {nil, _said} -> nil
      {title, {:user, text}} -> if first_line(text) == title, do: nil, else: said(said)
      {_title, _said} -> said(said)
    end
  end

  defp first_line(text),
    do: text |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 140)

  defp opening_title(nil), do: nil
  defp opening_title(""), do: nil
  defp opening_title(text), do: String.slice(text, 0, 140)

  defp said(nil), do: "Nothing said yet."

  defp said({role, text}) do
    line = text |> String.split("\n", trim: true) |> List.first("") |> String.slice(0, 140)
    if role == :user, do: "you: " <> line, else: "agent: " <> line
  end

  # -- the parts ----------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :project, :map, required: true
  attr :clone_url, :string, required: true
  attr :mirrors, :list, required: true
  attr :listed, :integer, required: true
  attr :spent, :any, required: true
  attr :proposals, :list, required: true
  attr :forge_release, :any, required: true
  attr :latest_release, :any, required: true

  # The project's facts (`7f`): drawn in the details panel and, from 768, as the page's rail.
  defp facts(assigns) do
    ~H"""
    <div id={@id} class="project-facts-body">
      <.copyable id={@id <> "-clone-url"} value={@clone_url} label={@project.name} />
      <.fact_list dense class="project-fact-list">
        <:fact label="default branch">{@project.default_branch}</:fact>
        <:fact label="forge release">{forge_release_line(@forge_release)}</:fact>
        <:fact :if={@latest_release} label="latest release">
          <ReleaseComponents.latest
            id={@id <> "-latest-release"}
            record={@latest_release}
            project={@project}
          />
        </:fact>
        <:fact label="mirror" tone={mirror_failing?(@mirrors) && "danger"}>
          {mirror_summary(@mirrors)}
        </:fact>
        <:fact :if={@project.seed_id} label="worker seed">
          {String.slice(@project.seed_id, 0, 16)}
        </:fact>
        <:fact label="tickets">{@listed}</:fact>
        <:fact :if={@proposals != []} label="proposals">{length(@proposals)}</:fact>
        <:fact label="spent">{Format.windows(@spent) || "—"}</:fact>
      </.fact_list>
      <div class="project-facts-links">
        <.link navigate={~p"/projects/#{@project.name}/repo"} class="project-link">
          Repository ›
        </.link>
        <.link navigate={~p"/projects/#{@project.name}/releases"} class="project-link">
          Releases ›
        </.link>
        <.link navigate={~p"/projects/#{@project.name}/settings"} class="project-link">
          Settings ›
        </.link>
      </div>
    </div>
    """
  end

  attr :release, :any, required: true
  attr :project, :map, required: true
  attr :drafts, :map, required: true
  attr :error, :string, default: nil

  # The release block (`21c`, `21d`): a project admin's, in `+ New`. Starting a release creates a
  # ticket and approves nothing, so its button is an outline and never amber.
  defp release_block(assigns) do
    ~H"""
    <section id="release" class="release-block">
      <div class="release-head">
        <span class="release-mark" aria-hidden="true">⇡</span>
        <span class="release-title">{release_title(@release)}</span>
      </div>

      <p :if={match?({:open, _}, @release)} id="release-open" class="release-text">
        Only one at a time. It is a ticket like any other.
        <.link
          navigate={~p"/tickets/#{@project.name}/#{elem(@release, 1).number}"}
          class="release-link"
        >
          #{elem(@release, 1).number} {elem(@release, 1).title} ›
        </.link>
      </p>

      <p :if={@release == :none} id="release-none" class="release-text">
        {Admission.explain(:no_release_workflow)}. Set it in the workflow file that should be the
        release, under .forge/workflows/.
      </p>

      <p :if={match?({:several, _}, @release)} id="release-several" class="release-text">
        {Admission.explain({:several_release_workflows, elem(@release, 1)})}.
      </p>

      <p :if={match?({:broken, _}, @release)} id="release-broken" class="release-text">
        The release, {elem(@release, 1).path}, cannot start: {Admission.explain(
          elem(elem(@release, 1).workflow, 1)
        )}.
      </p>

      <p :if={match?({:ready, _}, @release)} class="release-text release-file">
        {elem(@release, 1).path}
      </p>

      <%!-- A note typed and not sent, in a state with no box to hold it: another admin started a
            release, or the flag moved, while this page was open. Shown, not lost. --%>
      <div
        :if={
          not match?({tag, _} when tag in [:ready, :broken], @release) and
            Drafts.field(@drafts, "release", "note") != ""
        }
        id="release-draft"
        class="release-draft"
      >
        <.eyebrow>Your unsent note</.eyebrow>
        <p class="release-draft-text whitespace-pre-line break-words">
          {Drafts.field(@drafts, "release", "note")}
        </p>
      </div>

      <.error_note :if={@error} id="release-error">{@error}</.error_note>

      <.form
        :if={match?({tag, _} when tag in [:ready, :broken], @release)}
        for={%{}}
        id="release-form"
        phx-change="draft:change"
        phx-submit="release:start"
        class="release-form"
      >
        <input type="hidden" name="draft" value="release" />
        <ForgeWeb.Conversations.message_box
          id="release-note"
          name="note"
          rows="3"
          value={Drafts.field(@drafts, "release", "note")}
          enter={:newline}
          label="Note for the release, optional"
          placeholder="What this release is for, or what to leave out"
        />
        <.button
          type="submit"
          variant="outline"
          disabled={match?({:broken, _}, @release)}
          phx-disable-with="Starting…"
        >
          Start the release
        </.button>
      </.form>
    </section>
    """
  end

  defp release_title({:open, _ticket}), do: "A release is already open"
  defp release_title({:ready, _entry}), do: "Release"
  defp release_title({:broken, _entry}), do: "Can't start"
  defp release_title(:none), do: "No release"
  defp release_title({:several, _paths}), do: "Two releases"

  attr :entry, :map, required: true
  attr :place, :map, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true

  # Where a queued ticket stands and what is happening to it, said once: a ticket being merged or
  # integrated has no place to name beside it, and "being integrated · being integrated" said it
  # twice.
  # The rank numeral is the place, so the line says only what is happening: "2nd of 2" beside a
  # `2` said it twice.
  defp merge_line(place), do: merge_queue_doing(place)

  # One merge-queue row (`7b`): the place as the headline, the ticket, its state and what is
  # happening to it, and the way out. The title is wrapped and cut at two lines (HEEx escapes it,
  # so markup in a title is text).
  defp queue_row(assigns) do
    ~H"""
    <li id={"queue-#{@entry.ticket_id}"} class="merge-row">
      <span class="merge-place" aria-label={merge_queue_place(@place)}>{@place.index}</span>
      <div class="merge-body">
        <.link
          navigate={~p"/tickets/#{@project}/#{@entry.ticket.number}"}
          class="merge-ticket"
        >
          <span class="merge-number">#{@entry.ticket.number}</span>
          <span class="merge-title line-clamp-2 break-words">{@entry.ticket.title}</span>
        </.link>
        <span class="merge-doing">
          <span class="merge-state">{@entry.ticket.state}</span>
          {merge_line(@place)} · approved {Format.ago_phrase(@entry.inserted_at, @now)}
        </span>
      </div>
      <.confirm
        id={"merge-take-out-#{@entry.ticket_id}"}
        label="Take out"
        act="Take it out"
        sentence={ForgeWeb.Operator.Components.take_out_sentence()}
        class="merge-take-out"
        phx-click="take-out"
        phx-value-ticket={@entry.ticket_id}
        phx-disable-with="Taking out…"
      />
    </li>
    """
  end

  attr :summary, :map, required: true
  attr :proposed, :map, required: true
  attr :opening, :string, default: nil
  attr :now, :any, required: true

  # One conversation (`7c`): what it was opened with, which is what tells one from another, then
  # whether it waits, runs or when it was last used, the proposals it wrote and what it spent, and
  # its last line beneath. One with no opening yet is named by its last line, as before.
  defp chat_row(assigns) do
    ~H"""
    <li id={"conversation-#{@summary.chat.id}"}>
      <.list_row
        navigate={~p"/chats/#{@summary.chat.id}"}
        title={opening_title(@opening) || said(@summary.said)}
        latest={chat_latest(@opening, @summary.said)}
        kicker={@summary.ticket && "##{@summary.ticket.number}"}
        edge={if @summary.waiting, do: "accent"}
      >
        <:meta>
          <.state_label :if={@summary.waiting} state="waiting">waiting on you</.state_label>
          <.state_label :if={@summary.live and not @summary.waiting} state="running">
            live
          </.state_label>
          <.state_label :if={not @summary.live} state="idle">{@summary.chat.status}</.state_label>
          <span>{Format.ago(@summary.at, @now)}</span>
          <span :if={proposals_on(@proposed, @summary.chat.id)}>
            {proposals_on(@proposed, @summary.chat.id)}
          </span>
          <span :if={(@summary.chat.turns || 0) > 0}>
            {Format.counted(@summary.chat.turns, "turn")}
          </span>
          <span :if={Format.spent(@summary.chat.usage)}>
            {Format.spent(@summary.chat.usage)}
          </span>
        </:meta>
      </.list_row>
    </li>
    """
  end

  # The Proposals view keeps the project's title and `+ New` (it is one of the project's views,
  # as the strip says); what it holds is said in the subline.
  defp proposals_subline(assigns) do
    "#{Format.counted(length(assigns.proposals), "proposal")} · " <>
      Format.counted(length(assigns.groups), "source")
  end

  # The proposal the reader shows: the one in `?read=`, else the first of the pass, which a phone
  # does not show until one is chosen and a desktop shows beside the list (`8e`).
  defp reader_item(assigns) do
    order = ordered(assigns)
    id = if assigns.reading in order, do: assigns.reading, else: List.first(order)

    with id when not is_nil(id) <- id,
         group when not is_nil(group) <-
           Enum.find(assigns.groups, fn g -> Enum.any?(g.items, &(&1.version_id == id)) end) do
      item = Enum.find(group.items, &(&1.version_id == id))
      {item, group, {Enum.find_index(order, &(&1 == id)) + 1, length(order)}}
    end
  end

  attr :groups, :list, required: true
  attr :decided, :list, required: true
  attr :project, :map, required: true
  attr :plist, :string, required: true
  attr :selecting, :boolean, required: true
  attr :selected, :any, required: true
  attr :reading, :string, default: nil
  attr :current, :any, required: true
  attr :drafts, :map, required: true
  attr :proposal_error, :string, default: nil
  attr :history_error, :string, default: nil
  attr :current_scope, :map, required: true
  attr :skipped, :list, required: true
  attr :now, :any, required: true
  attr :rest, :global

  # The Proposals view (`8a`–`8g`): Open · Admitted · Declined; the open ones as groups with the
  # reader beside or below them; the decided ones as History.
  defp proposals_full(assigns) do
    assigns = assign(assigns, reader: reader_item(assigns))

    ~H"""
    <div class="proposals-full">
      <div class="project-section-head">
        <.segmented
          id="proposal-lists"
          size="sm"
          value={@plist}
          on_select="proposals:list"
          options={[
            {"Open", "open", length(ProposalsView.order(@groups))},
            {"Admitted", "admitted", Enum.count(@decided, &(&1.decision == :accepted))},
            {"Declined", "declined", Enum.count(@decided, &ProposalsView.still_declined?/1)}
          ]}
        />
        <.button
          :if={@plist == "open" and @groups != []}
          type="button"
          variant="quiet"
          size="sm"
          phx-click="proposals:selecting"
          value={if @selecting, do: "off", else: "on"}
          phx-value-value={if @selecting, do: "off", else: "on"}
        >
          {if @selecting, do: "Done", else: "Select"}
        </.button>
      </div>

      <div :if={@plist == "open"} class="proposals-open">
        <div class="proposals-list">
          <p class="project-hint">
            Work a job or a conversation said should exist. Nothing runs until you admit one.
          </p>
          <%!-- A refusal for a proposal the reader no longer has — decided meanwhile — is said at
                the head of the list, where the pass goes on. --%>
          <.error_note :if={@proposal_error && !@reader} id="proposal-error">
            {@proposal_error}
          </.error_note>
          <p :if={@groups == []} class="project-empty">No proposals waiting.</p>
          <ProposalsView.list
            groups={@groups}
            project={@project.name}
            selecting={@selecting}
            selected={@selected}
            reading={@reading}
            now={@now}
          />
        </div>
        <div :if={@reader} class="proposals-reader">
          <.link patch={~p"/projects/#{@project.name}?#{[view: "proposals"]}"} class="proposal-back">
            ‹ Proposals
          </.link>
          <ProposalsView.reader
            item={elem(@reader, 0)}
            group={elem(@reader, 1)}
            position={elem(@reader, 2)}
            types={choosable(@current)}
            drafts={@drafts}
            error={@proposal_error}
            now={@now}
          />
        </div>
      </div>

      <div :if={@plist != "open"} class="proposals-history">
        <.error_note :if={@history_error} id="history-error">
          {@history_error}
        </.error_note>
        <ProposalsView.history
          entries={Enum.filter(@decided, &(&1.decision == decision(@plist)))}
          project={@project.name}
          viewer={@current_scope.user.id}
          now={@now}
        />
      </div>
    </div>
    """
  end

  defp decision("admitted"), do: :accepted
  defp decision(_declined), do: :declined

  # -- the page -----------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown: filtered(assigns.rows, assigns.filter, assigns.state),
        shown_type: shown_type(assigns.current, assigns.type, assigns.rows),
        open_by_type: open_by_type(assigns.rows)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@project.name}
      subline={if @view == "proposals", do: proposals_subline(assigns), else: subline(@rows)}
      context={{"+ New", ~p"/projects/#{@project.name}?#{[view: @view, new: ""]}"}}
      back={
        if @view == "proposals",
          do: {@project.name, ~p"/projects/#{@project.name}"},
          else: {"Projects", ~p"/projects"}
      }
      views={views(assigns)}
      view={@view}
      measure={nil}
    >
      <:details>
        <.facts
          id="details-facts"
          project={@project}
          clone_url={@clone_url}
          mirrors={@mirrors}
          listed={@listed}
          spent={@spent}
          proposals={@proposals}
          forge_release={@forge_release}
          latest_release={@latest_release}
        />
      </:details>

      <:composer :if={@view == "chats"}>
        <.chat_start drafts={@drafts} project={@project} error={@chat_error} />
      </:composer>
      <%!-- While some are picked the bulk bar takes the foot (`8c`). --%>
      <:composer :if={@view == "proposals" and @selecting and MapSet.size(@selected) > 0}>
        <ProposalsView.bulk
          count={MapSet.size(@selected)}
          types={choosable(@current)}
          drafts={@drafts}
          error={@bulk_error}
        />
      </:composer>

      <div
        id="project-page"
        class="project-page"
        data-view={@view}
        data-reading={to_string(@view == "proposals" and @reading != nil)}
      >
        <div class="project-head">
          <%!-- On a desktop the title row has no `+ New`: these are its parts, in the page. --%>
          <div class="project-actions">
            <.button
              navigate={~p"/tickets/new?#{[project: @project.name]}"}
              variant="outline"
              size="desk"
            >
              + New ticket
            </.button>
            <.button
              navigate={~p"/chats/new?#{[project: @project.name]}"}
              variant="outline"
              size="desk"
            >
              + New chat
            </.button>
            <.button
              :if={@release}
              type="button"
              variant="outline"
              size="desk"
              phx-click={open_sheet("new-sheet")}
            >
              Release…
            </.button>
          </div>

          <%!-- Above every view, so a phone showing one view at a time still sees it. --%>
          <div :if={@forge_release not in [:current, :empty]} class="project-notices">
            <.forge_release_notice status={@forge_release} project={@project} />
          </div>
        </div>

        <section id="project-tickets" class="project-section" data-section="tickets">
          <div class="project-section-head">
            <.eyebrow>Open tickets · {length(@rows)}</.eyebrow>
            <.segmented
              id="ticket-filter"
              size="sm"
              value={@filter}
              on_select="tickets:filter"
              options={[
                {"All", "open", length(@rows)},
                {"Waiting", "waiting", waiting_count(@rows)},
                {"Running", "running", running_count(@rows)}
              ]}
            />
          </div>

          <p :if={@state} id="ticket-state-filter" class="project-filter">
            in {@state}
            <.link
              patch={~p"/projects/#{@project.name}?#{[view: @view]}"}
              aria-label="Show every state"
            >
              ×
            </.link>
          </p>

          <p :if={@rows == []} id="tickets-none" class="project-empty">
            No tickets yet.
            <.link navigate={~p"/tickets/new?#{[project: @project.name]}"} class="project-link">
              Admit the first one ›
            </.link>
          </p>
          <p :if={@rows != [] and @shown == []} class="project-empty">Nothing here.</p>

          <div class="project-ticket-list">
            <.eyebrow :if={Enum.any?(@shown, & &1.waiting)} tone="accent">Waiting on you</.eyebrow>
            <ProjectTickets.list
              id="tickets-waiting"
              rows={Enum.filter(@shown, & &1.waiting)}
              project={@project.name}
              now={@now}
            />
            <.eyebrow :if={Enum.any?(@shown, &(not &1.waiting))}>In progress</.eyebrow>
            <ProjectTickets.list
              id="tickets-rest"
              rows={Enum.reject(@shown, & &1.waiting)}
              project={@project.name}
              now={@now}
            />
          </div>
          <ProjectTickets.table
            :if={@shown != []}
            id="tickets-table"
            rows={@shown}
            project={@project.name}
            now={@now}
          />
          <ProjectTickets.history tickets={@history} project={@project.name} now={@now} />
        </section>

        <div class="project-side">
          <section id="project-proposals" class="project-section" data-section="proposals">
            <%!-- From 768, outside the Proposals view: the open ones in brief, each opening the
                  reader. The view itself is below. --%>
            <div class="proposals-overview">
              <div class="project-section-head">
                <.eyebrow tone={@proposals != [] && "accent"}>
                  Proposals · {length(@proposals)}
                </.eyebrow>
                <.link
                  :if={@proposals != []}
                  patch={~p"/projects/#{@project.name}?#{[view: "proposals"]}"}
                  class="project-link"
                >
                  Review {length(@proposals)} ›
                </.link>
              </div>
              <ol class="proposal-rail proposal-rail--brief">
                <li :for={item <- Enum.take(@proposals, 5)}>
                  <.link
                    patch={
                      ~p"/projects/#{@project.name}?#{[view: "proposals", read: item.version_id]}"
                    }
                    class="proposal-row"
                  >
                    <span class="proposal-row-text">
                      <span class="proposal-row-title">{item.title || "Could not be read"}</span>
                      <span class="proposal-row-body">{item.body}</span>
                    </span>
                  </.link>
                </li>
              </ol>
              <p :if={@proposals == []} class="project-empty">No proposals waiting.</p>
            </div>

            <.proposals_full {assigns} />
          </section>

          <%!-- The merge queue: approved tickets waiting to merge, in the order they were approved.
                Never the operator's queue, the page of decisions (`docs/design/ui.md` § Merge). --%>
          <section id="merge-queue" class="project-section" data-section="merge">
            <Actions.refused id="merge-refusal" refusal={@refusal} at={["take-out"]} />
            <.eyebrow>Merge queue · {length(@queue)}</.eyebrow>
            <ol :if={@queue != []} id="merge-queue-list" class="merge-rows">
              <.queue_row
                :for={{{entry, place}, index} <- Enum.with_index(@queue)}
                :if={index < queue_rows()}
                entry={entry}
                place={place}
                project={@project.name}
                now={@now}
              />
            </ol>
            <ol :if={length(@queue) > queue_rows()} id="merge-queue-more" class="merge-rows hidden">
              <.queue_row
                :for={{entry, place} <- Enum.drop(@queue, queue_rows())}
                entry={entry}
                place={place}
                project={@project.name}
                now={@now}
              />
            </ol>
            <button
              :if={length(@queue) > queue_rows()}
              type="button"
              id="merge-queue-expand"
              phx-click={JS.show(to: "#merge-queue-more", display: "flex") |> JS.hide()}
              class="project-more"
            >
              {length(@queue) - queue_rows()} more ↓
            </button>
            <p :if={@queueing != []} id="merge-queue-empty" class="project-hint">
              {if @queue == [], do: "Nothing is waiting to merge. "}Approving a ticket on {Enum.join(
                @queueing,
                ", "
              )} adds it here. Taking one out withdraws its approval; an integration already running
              finishes but does not merge.
            </p>
            <p :if={@queue == [] and @queueing == []} id="merge-queue-empty" class="project-empty">
              Nothing is waiting to merge.
            </p>

            <div :if={@merged != []} id="recent-merges" class="recent-merges">
              <.eyebrow>Merged lately</.eyebrow>
              <ol>
                <li :for={merge <- @merged}>
                  <.link
                    navigate={~p"/tickets/#{@project.name}/#{merge.ticket.number}"}
                    class="recent-merge"
                  >
                    <span class="recent-merge-sha">{merge.sha && String.slice(merge.sha, 0, 7)}</span>
                    <span class="merge-number">#{merge.ticket.number}</span>
                    <span class="recent-merge-title">{merge.ticket.title}</span>
                    <span class="ticket-row-age">{Format.ago(merge.at, @now)}</span>
                  </.link>
                </li>
              </ol>
            </div>
          </section>

          <section id="project-chats" class="project-section" data-section="chats">
            <%!-- `+ New chat` is the page's action row's, once. --%>
            <.eyebrow>Conversations · {length(@chats)}</.eyebrow>
            <p :if={@chats == []} class="project-empty">
              None yet. A chat is for the work that does not fit a ticket.
            </p>
            <section :if={Enum.any?(@chats, & &1.live)} id="conversations-live">
              <h3 class="project-subhead">Live · {Enum.count(@chats, & &1.live)}</h3>
              <ol class="project-chat-rows">
                <.chat_row
                  :for={summary <- Enum.filter(@chats, & &1.live)}
                  summary={summary}
                  proposed={@proposed}
                  opening={@openings[summary.chat.id]}
                  now={@now}
                />
              </ol>
            </section>
            <section :if={Enum.any?(@chats, &(not &1.live))} id="conversations-earlier">
              <h3 :if={Enum.any?(@chats, & &1.live)} class="project-subhead">Earlier</h3>
              <ol class="project-chat-rows">
                <.chat_row
                  :for={summary <- Enum.reject(@chats, & &1.live)}
                  summary={summary}
                  proposed={@proposed}
                  opening={@openings[summary.chat.id]}
                  now={@now}
                />
              </ol>
            </section>
            <p class="project-hint">
              A chat is for the work that doesn't fit a ticket. A ticket's own chat steps live on
              the ticket.
            </p>
          </section>
        </div>

        <section id="project-workflow" class="project-section" data-section="workflow">
          <div class="project-section-head">
            <.eyebrow>How a new ticket moves</.eyebrow>
            <.segmented
              :if={length(current_types(@current)) > 1}
              id="workflow-types"
              size="sm"
              value={@shown_type && @shown_type.name}
              on_select="workflow:type"
              options={
                Enum.map(
                  current_types(@current),
                  &{&1.name, &1.name, Map.get(@open_by_type, &1.name, 0)}
                )
              }
            />
          </div>
          <p class="project-hint">
            The repository's workflow now, which the next ticket will pin; an open ticket follows
            the one it pinned.
          </p>

          <.notice :if={match?({:error, _reason}, @current)} tone="danger">
            This project cannot take a ticket: {Admission.explain(elem(@current, 1))}. A workflow
            lives in the repository, so it is pushed rather than edited here.
          </.notice>

          <%!-- One per ticket type, each with its own states, the one the switch shows drawn and
                the rest hidden; a broken one says why. See docs/design/ticket-types.md § The
                project page. --%>
          <section
            :for={type <- current_types(@current)}
            id={type_id(type)}
            class="workflow-type"
            hidden={type != @shown_type}
          >
            <div class="workflow-source">
              <h3 :if={type.name} class="workflow-type-name">{type.name}</h3>
              <span :if={type.release} class="workflow-release">the release</span>
              <span :if={description(type)}>{description(type)}</span>
            </div>
            <p class="project-hint">
              From <span class="font-mono">{type.path}</span>. Edited by pushing, not here.
            </p>

            <.notice :if={not Admission.ready?(type.workflow)} tone="danger">
              {if type.name, do: "This type", else: "This project"} cannot take a ticket: {Admission.explain(
                elem(type.workflow, 1)
              )}.
            </.notice>

            <div :if={Admission.ready?(type.workflow)} class="workflow-flow-wrap">
              <WorkflowMap.flow
                id={workflow_id(type)}
                workflow={elem(type.workflow, 1)}
                counts={
                  @rows
                  |> Enum.filter(&(&1.ticket.ticket_type == type.name))
                  |> Enum.frequencies_by(& &1.ticket.state)
                }
              />
            </div>
            <div :if={Admission.ready?(type.workflow)} class="workflow-map-wrap">
              <WorkflowMap.map
                id={"map-#{type.name || "workflow"}"}
                workflow={elem(type.workflow, 1)}
                dots={ProjectTickets.dots(Enum.filter(@rows, &(&1.ticket.ticket_type == type.name)))}
                selected={@state}
                filter={&~p"/projects/#{@project.name}?#{[view: @view, state: &1]}"}
              />
              <p class="workflow-legend">
                <span class="wf-map-dot-key wf-map-dot--waiting" /> waiting on you
                <span class="wf-map-dot-key wf-map-dot--running" /> running
                <span class="wf-map-dot-key wf-map-dot--stuck" /> stuck
                <span class="wf-map-dot-key wf-map-dot--idle" /> idle
              </p>
            </div>
          </section>

          <div :if={not_types(@current) != []} id="not-types" class="not-types">
            <.eyebrow>In .forge/workflows/ but not a type</.eyebrow>
            <p :for={entry <- not_types(@current)}>
              <span class="font-mono">{entry.path}</span> — {entry.why}
            </p>
          </div>
        </section>

        <aside class="project-rail">
          <.facts
            id="rail-facts"
            project={@project}
            clone_url={@clone_url}
            mirrors={@mirrors}
            listed={@listed}
            spent={@spent}
            proposals={@proposals}
            forge_release={@forge_release}
            latest_release={@latest_release}
          />
        </aside>
      </div>

      <.sheet id="new-sheet" label={"New in #{@project.name}"} title={"New in #{@project.name}"}>
        <div class="new-sheet">
          <.link navigate={~p"/tickets/new?#{[project: @project.name]}"} class="new-sheet-row">
            <span class="new-sheet-name">New ticket</span>
            <span class="new-sheet-detail">Title, body, type. Admitted to its workflow.</span>
            <span aria-hidden="true" class="new-sheet-chevron">›</span>
          </.link>
          <.link navigate={~p"/chats/new?#{[project: @project.name]}"} class="new-sheet-row">
            <span class="new-sheet-name">New chat</span>
            <span class="new-sheet-detail">
              A conversation about {@project.name}, on its own branch.
            </span>
            <span aria-hidden="true" class="new-sheet-chevron">›</span>
          </.link>
          <%!-- A project admin's and nobody else's (`docs/design/ticket-types.md` § Releases). --%>
          <.release_block
            :if={@release}
            release={@release}
            project={@project}
            drafts={@drafts}
            error={@release_error}
          />
          <%!-- A refusal for someone drawn no block — a member who sent the event anyway — is
                said here, where the block would be. --%>
          <.error_note :if={!@release && @release_error} id="release-error">
            {@release_error}
          </.error_note>
        </div>
      </.sheet>
      <%!-- A view named in the address on a wide screen, where every view is on one page: the page
            opens scrolled to it, so a shared link to the workflow lands on the workflow. --%>
      <span
        :if={@view_given}
        id="view-scroller"
        phx-hook=".ScrollToView"
        data-section={@view}
        hidden
      />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToView">
        export default {
          mounted() {
            if (!window.matchMedia("(min-width: 1440px)").matches) return
            document.querySelector(`#project-page [data-section="${this.el.dataset.section}"]`)
              ?.scrollIntoView({block: "start"})
          }
        }
      </script>
      <%!-- `?new` is how the top bar's `+ New`, a link, opens the sheet: on mount, once. --%>
      <span :if={@new} id="new-sheet-opener" phx-hook=".OpenSheet" data-sheet="new-sheet" hidden />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenSheet">
        export default {
          mounted() {
            document.getElementById(this.el.dataset.sheet)
              ?.dispatchEvent(new CustomEvent("forge:sheet-open"))
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :drafts, :map, required: true
  attr :project, :map, required: true
  attr :error, :string, default: nil

  # The Chats view's composer (`7c`): starts a conversation in place with the project fixed. A
  # form with an id and a `phx-change`, so a rejoin gives back what was typed.
  defp chat_start(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="chat-start"
      phx-change="draft:change"
      phx-submit="chat:start"
      class="chat-start"
    >
      <input type="hidden" name="draft" value="chat" />
      <.error_note :if={@error} id="chat-start-error" class="chat-start-error">{@error}</.error_note>
      <.composer
        id="chat-start-text"
        name="text"
        value={Drafts.field(@drafts, "chat", "text")}
        placeholder={"Start a chat about #{@project.name}"}
      />
    </.form>
    """
  end
end
