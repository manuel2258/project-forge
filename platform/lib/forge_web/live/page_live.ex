defmodule ForgeWeb.PageLive do
  @moduledoc """
  A page an agent wrote, opened inside a forge page of its own (`docs/design/ui.md` § Pages,
  `docs/design/pages.md` § What a person's page does): at `/tickets/:project/:number/pages/:name`
  and `/chats/:id/pages/:name`, always at the latest version.

  **Two things sit on this screen and only one of them is forge's.** The bar — a way back, the
  page's name, who wrote it, whether its data is saved, why it is read only, the outside-access
  toggle — is forge's own markup, outside the frame, so nothing the page draws can cover, move or
  restyle it. The frame is a sandboxed `iframe` (`sandbox="allow-scripts"`, never
  `allow-same-origin`) whose address carries a signed token (`ForgeWeb.PageToken`) because the
  document has an opaque origin and sends no cookie.

  **The frame never speaks to forge.** The page's script sends messages to this view's hook
  (`assets/js/page_frame.js`), which acts on one only when it comes from the frame's own window,
  and the hook sends this process the five things a page may do: `page:hello`, `page:get`,
  `page:all` and `page:batch`, which holds the sets and deletes. **No message names a page, a
  ticket or a project**: this process knows its own page, which it resolved from the address under
  the viewer's own membership on mount, and every write is the viewer's, through
  `Forge.Operator.write_page/5`, which checks again.

  **A value is never drawn here.** It is handed to the hook as data and only the page itself draws
  it, so there is no markup of a value to escape and no table of a page's data in forge's screens.
  """

  use ForgeWeb, :live_view

  alias Forge.{Conversations, Events, Jobs, Operator, Pages, Tickets}
  alias Forge.Pages.Batches
  alias ForgeWeb.PageToken

  # More operations than this in one batch is not a page's typing: the hook sends the last value of
  # each key, and a page holds at most `Forge.Pages.limits()[:keys]` of them.
  @max_ops 5_000
  # Well inside the 24 hours a `PageToken` lives.
  @refresh_ms 20 * 60 * 60 * 1000

  @doc """
  How long a view lets its frame's signed address age before it signs a fresh one and tells the
  hook (`:page_refresh_ms` in the application environment, which a test shortens).
  """
  @spec refresh_ms() :: pos_integer()
  def refresh_ms, do: Application.get_env(:forge, :page_refresh_ms, @refresh_ms)

  @impl true
  def mount(%{"project" => name, "number" => number, "name" => page_name}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    open(socket, project, {:ticket, ticket.id}, page_name, %{
      back: ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs",
      back_label: "#{project.name}##{ticket.number}",
      path: ~p"/tickets/#{project.name}/#{ticket.number}/pages/#{page_name}"
    })
  end

  def mount(%{"id" => id, "name" => page_name}, _session, socket) do
    chat = Conversations.get!(id)
    %{project: project, ticket: ticket} = Conversations.context(chat)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    # A ticket chat's page is the ticket's; a project chat's is the chat's own.
    scope = if ticket, do: {:ticket, ticket.id}, else: {:chat, chat.id}

    open(socket, project, scope, page_name, %{
      back: ~p"/chats/#{chat.id}",
      back_label: "chat",
      path: ~p"/chats/#{chat.id}/pages/#{page_name}"
    })
  end

  # A page with no version has no row to open: it is not found, as a ticket the viewer does not
  # reach is, and the queue draws *no version yet* where a person was to open one.
  defp open(socket, project, scope, page_name, where) do
    with %Pages.Page{} = page <- Pages.get(scope, page_name),
         %Pages.Version{} = version <- Pages.latest_version(page) do
      if connected?(socket) do
        Pages.subscribe(page.id)
        subscribe(scope)
      end

      user = socket.assigns.current_scope.user

      {:ok,
       socket
       |> assign(
         page_title: page.name,
         project: project,
         scope: scope,
         page: page,
         version: version,
         where: where,
         user: user,
         by: written_by(version),
         read_only: Pages.read_only(scope),
         outside: Pages.outside?(user.id, page.id),
         newer: false,
         # The writes this process made, by key, that have not yet come back round on the page's
         # topic: each is told to the viewer's own frame by the hook already, and not again.
         own: %{},
         frame_src: frame_src(user, page, version)
       )
       |> schedule_refresh()}
    else
      nil -> raise Ecto.NoResultsError, queryable: Pages.Page
    end
  end

  # The frame's address carries a token that is good for 24 hours (`PageToken`), so it is signed
  # again whenever the frame is to be loaded again, and on a timer for a page left open for days.
  defp frame_src(user, page, version),
    do: ~p"/page-files/#{PageToken.sign(user.id, page.id, version.version)}/index.html"

  defp schedule_refresh(socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_frame, refresh_ms())
    socket
  end

  # Read-only changes arrive on the global topics, so each is filtered by id before anything else
  # is read (`CLAUDE.md` § Rules).
  defp subscribe({:ticket, _id}), do: Events.subscribe()
  defp subscribe({:chat, _id}), do: Events.subscribe_chats()

  defp written_by(%{job_id: nil, version: version}), do: "written by an agent · v#{version}"

  defp written_by(%{job_id: job_id, version: version}) do
    case Jobs.get(job_id) do
      %{kind: :chat} -> "written in a chat · v#{version}"
      %{state: state} -> "written by an agent in #{state} · v#{version}"
      nil -> "written by an agent · v#{version}"
    end
  end

  # -- what the frame asks -----------------------------------------------------------------------

  @impl true
  def handle_event("page:hello", _params, socket) do
    {:reply,
     Map.put(read_only_state(socket.assigns.read_only), :viewer, socket.assigns.user.email),
     socket}
  end

  def handle_event("page:get", %{"key" => key}, socket) when is_binary(key) do
    reply =
      case Pages.entry(socket.assigns.page, key) do
        nil -> %{value: nil, counter: nil}
        entry -> %{value: entry.value, counter: entry.counter}
      end

    {:reply, reply, socket}
  end

  def handle_event("page:get", _params, socket), do: {:reply, %{value: nil, counter: nil}, socket}

  def handle_event("page:all", _params, socket) do
    entries =
      Map.new(
        Pages.entries(socket.assigns.page),
        &{&1.key, %{value: &1.value, counter: &1.counter}}
      )

    {:reply, %{entries: entries}, socket}
  end

  def handle_event("page:batch", %{"client" => client, "seq" => seq, "ops" => ops}, socket)
      when is_binary(client) and is_integer(seq) and is_list(ops) and length(ops) <= @max_ops do
    page = socket.assigns.page

    if Batches.applied?(page.id, client, seq) do
      {:reply, %{duplicate: true}, socket}
    else
      {results, socket} = Enum.map_reduce(ops, socket, &apply_op/2)
      Batches.applied(page.id, client, seq)
      {:reply, %{results: results}, socket}
    end
  end

  def handle_event("page:batch", _params, socket), do: {:reply, %{results: []}, socket}

  # The toggle is the viewer's own, for this page only; the frame is asked for again so that its
  # response carries the policy as it now stands.
  def handle_event("outside", _params, socket) do
    %{page: page, outside: outside} = socket.assigns

    case Operator.set_page_outside(page, socket.assigns.user, not outside) do
      {:ok, now} -> {:noreply, socket |> assign(outside: now) |> reload_frame("page:reload")}
      {:error, _refused} -> {:noreply, socket}
    end
  end

  # The frame is sent a freshly signed address, never its old one: a page left open longer than
  # the token lives would otherwise be loaded again into "not found".
  defp reload_frame(socket, event) do
    %{user: user, page: page, version: version} = socket.assigns
    push_event(socket, event, %{src: frame_src(user, page, version)})
  end

  defp apply_op(%{"op" => "set", "key" => key, "value" => value}, socket) when is_binary(key) do
    socket.assigns
    |> save(key, {:set, value})
    |> result(socket, key, :set)
  end

  defp apply_op(%{"op" => "set", "key" => key}, socket) when is_binary(key),
    do: apply_op(%{"op" => "set", "key" => key, "value" => nil}, socket)

  defp apply_op(%{"op" => "delete", "key" => key}, socket) when is_binary(key) do
    socket.assigns
    |> save(key, :delete)
    |> result(socket, key, :delete)
  end

  defp apply_op(_other, socket), do: {%{ok: false, reason: "not understood"}, socket}

  defp save(%{user: user, page: page}, key, op), do: Operator.write_page(page, user, key, op)

  # A write that came back is remembered by key, so the broadcast of it is not told to the frame
  # that made it. A delete of a key that is not there writes nothing and broadcasts nothing.
  defp result({:ok, none}, socket, _key, :delete) when none in [nil, :noop],
    do: {%{ok: true}, socket}

  defp result({:ok, _old}, socket, key, :delete), do: {%{ok: true}, remember(socket, key)}

  defp result({:ok, entry}, socket, key, :set),
    do: {%{ok: true, counter: entry.counter}, remember(socket, key)}

  defp result({:error, reason}, socket, _key, _op), do: {refusal(reason), socket}

  defp remember(socket, key), do: update(socket, :own, &Map.update(&1, key, 1, fn n -> n + 1 end))

  @doc false
  # What a person is told of a refused save: a few plain words, and the limit's number when it
  # was one. The bar draws them as *refused · reason (limit)*.
  @spec refusal(term()) :: map()
  def refusal({:read_only, reason}),
    do: %{ok: false, reason: "read only: " <> reason_text(reason)}

  def refusal({:limit, name, max}),
    do: %{ok: false, reason: "limit reached", limit: "#{name}: #{max} at most"}

  def refusal({:invalid_key, _why}), do: %{ok: false, reason: "that key is not allowed"}

  def refusal(:invalid_value),
    do: %{ok: false, reason: "that value is not JSON, or has a NUL character"}

  def refusal(:not_found), do: %{ok: false, reason: "the page is gone"}
  def refusal(_other), do: %{ok: false, reason: "not saved"}

  defp read_only_state(false), do: %{readOnly: false, reason: nil}
  defp read_only_state({true, reason}), do: %{readOnly: true, reason: reason_text(reason)}

  @doc false
  @spec reason_text(atom()) :: String.t()
  def reason_text(:done), do: "the ticket is done"
  def reason_text(:cancelled), do: "the ticket was cancelled"
  def reason_text(:chat_ended), do: "the chat has ended"

  # -- what happens elsewhere --------------------------------------------------------------------

  # Equivalent mutant, here and on `:page_published` below: the id match in the first head of each
  # can be dropped unseen, because the topic these arrive on is `page:<id>` of this view's own
  # page (`Pages.subscribe/1`) and nothing else publishes to it, so the second head never runs.
  @impl true
  def handle_info({:page_changed, id, change}, %{assigns: %{page: %{id: id}}} = socket) do
    me = socket.assigns.user.id

    if change.writer == {:user, me} and Map.has_key?(socket.assigns.own, change.key) do
      {:noreply, update(socket, :own, &drop_one(&1, change.key))}
    else
      {:noreply,
       push_event(socket, "page:changed", %{
         key: change.key,
         value: change.value,
         deleted: change.op == :delete,
         counter: change.counter
       })}
    end
  end

  def handle_info({:page_changed, _other, _change}, socket), do: {:noreply, socket}

  # A page open for a day is given a new address, which the hook applies when nothing is waiting
  # to be saved, so its lazily loaded images and video keep answering.
  def handle_info(:refresh_frame, socket),
    do: {:noreply, socket |> reload_frame("page:refresh") |> schedule_refresh()}

  def handle_info({:page_published, id, version}, %{assigns: %{page: %{id: id}}} = socket) do
    {:noreply, assign(socket, newer: version > socket.assigns.version.version)}
  end

  def handle_info({:page_published, _other, _version}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, %{assigns: %{scope: {:ticket, id}}} = socket),
    do: {:noreply, reread_read_only(socket)}

  def handle_info(
        {:chat_changed, id, _project, _ticket},
        %{assigns: %{scope: {:chat, id}}} = socket
      ),
      do: {:noreply, reread_read_only(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}
  def handle_info({:chat_changed, _id, _project, _ticket}, socket), do: {:noreply, socket}

  defp drop_one(own, key) do
    case own do
      %{^key => 1} -> Map.delete(own, key)
      %{^key => n} -> Map.put(own, key, n - 1)
    end
  end

  # Told to the frame only when it changed: a ticket changes for many reasons.
  defp reread_read_only(socket) do
    now = Pages.read_only(socket.assigns.scope)

    if now == socket.assigns.read_only do
      socket
    else
      socket |> assign(read_only: now) |> push_event("page:readonly", read_only_state(now))
    end
  end

  # -- the screen --------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="page-view" class="pg" phx-hook="PageFrame" data-outside={to_string(@outside)}>
      <header id="page-bar" class="pg-bar">
        <.link navigate={@where.back} class="pg-back" aria-label={"Back to #{@where.back_label}"}>
          <span aria-hidden="true">‹</span> <span class="pg-back-label">{@where.back_label}</span>
        </.link>
        <span id="page-name" class="pg-name" title={@page.name}>{@page.name}</span>
        <span class="pg-by">{@by}</span>
        <%!-- Drawn by the hook, which also holds the unsent saves, so that it can change while the
              socket is down: the server never patches it (`ui.md` § Pages). --%>
        <span
          id="page-save"
          class="pg-save"
          role="status"
          aria-live="polite"
          data-page-save
          data-state="saved"
          phx-update="ignore"
        >
          saved
        </span>
        <span :if={@read_only != false} id="page-read-only" class="pg-read-only">
          read only · {read_only_reason(@read_only)}
        </span>
        <a :if={@newer} id="page-newer" class="pg-newer" href={@where.path}>newer version · reload</a>
        <button
          id="page-outside"
          type="button"
          class="pg-outside"
          phx-click="outside"
          aria-pressed={to_string(@outside)}
          title="Let this page reach any outside address, for you alone, on this page. Off, it reaches nothing outside forge."
        >
          <span>Outside<span class="pg-outside-long"> addresses</span></span>
          <span class="pg-outside-state">{if @outside, do: "on", else: "off"}</span>
        </button>
      </header>
      <%!-- Never patched: the frame's address is read once, and a new version is offered in the
            bar rather than loaded under the person. --%>
      <div id="page-frame-box" class="pg-frame" phx-update="ignore">
        <iframe
          id="page-frame"
          title={"The page #{@page.name}"}
          src={@frame_src}
          sandbox="allow-scripts"
          referrerpolicy="no-referrer"
          allowfullscreen
        ></iframe>
      </div>
    </div>
    """
  end

  defp read_only_reason({true, reason}), do: reason_text(reason)
end
