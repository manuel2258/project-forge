defmodule ForgeWeb.QueueLive do
  @moduledoc """
  The home screen: one ordered list of decisions, oldest first, answerable in place.

  No tabs and no filters — the operator must be able to reach the end and know they are done.
  Items are separated by a 1px rule rather than drawn as cards, and the measure does not widen
  on a laptop, because width only lets a second item compete for the same glance.

  An item is **one interruption, not one question**: a job that stops inside a document
  typically stops with several questions, and one card per question would turn three decisions
  into twenty items with identical timestamps. `Forge.Queue` keeps its per-question shape,
  because the JSON API and the CLI are built on it; the grouping is this page's presentation.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Conversations, Events, Operator, Push, Queue, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Queue", push_key: Push.enabled?() && Push.public_key())
     |> load()}
  end

  defp load(socket) do
    items =
      Queue.items(socket.assigns.current_scope.user)
      |> Enum.map(&Map.put(&1, :project, &1.project.name))
      |> group()
      |> Enum.map(&decorate/1)

    {waiting, digest} = Enum.split_with(items, & &1.actionable)

    assign(socket,
      items: waiting,
      digest: digest,
      decisions: Enum.sum(Enum.map(waiting, & &1.decisions)),
      now: DateTime.utc_now()
    )
  end

  # One job, stopped, against one artifact version, carrying N questions. Everything else is
  # already one interruption on its own.
  defp group(items) do
    {questions, rest} = Enum.split_with(items, &(&1.kind == :question))

    questions
    |> Enum.group_by(& &1.question.artifact_version_id)
    |> Enum.map(fn {_version_id, group} ->
      first = hd(group)

      %{
        kind: :questions,
        ticket: first.ticket,
        project: first.project,
        since: group |> Enum.map(& &1.since) |> Enum.min(DateTime),
        questions: Enum.map(group, & &1.question),
        version: first.question.artifact_version,
        detail: %{}
      }
    end)
    |> Enum.concat(rest)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  defp decorate(item) do
    item
    |> Map.put(:topology, topology(item.ticket))
    |> Map.put(:decisions, decisions(item))
    |> Map.put(:actionable, actionable?(item))
    |> Map.put_new(:questions, [])
    |> Map.put_new(:version, nil)
    |> put_approve()
  end

  # A blocking question has halted a job; a non-blocking one has not, and must never compete
  # with work that is actually waiting.
  #
  # `Forge.Queue.questions/1` is where that is enforced — it filters on `blocking` before an item
  # is built, so this list cannot hold a non-blocking question and the check below is always
  # true. Kept as a statement of the rule at the point it is relied on, not as a second defence:
  # no test can tell it from `is_list/1`, and the rule is tested one layer up, where it is real.
  defp actionable?(%{kind: :questions} = item), do: Enum.any?(item.questions, & &1.blocking)
  defp actionable?(_item), do: true

  defp decisions(%{kind: :questions} = item), do: length(item.questions)
  defp decisions(_item), do: 1

  defp put_approve(%{kind: :approval, ticket: ticket, detail: detail} = item) do
    approve =
      for name <- List.wrap(detail["approve"]),
          version = Artifacts.latest(ticket.id, name),
          do: {name, version.version}

    Map.put(item, :approve, approve)
  end

  defp put_approve(item), do: Map.put(item, :approve, [])

  # A ticket carries its own pinned workflow; one that no longer parses has no topology to read,
  # and a conversation has no workflow at all.
  defp topology(nil), do: :unknown

  defp topology(ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Board.topology(workflow, ticket.state)
      {:error, _errors} -> :unknown
    end
  end

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

  # Answering from the queue sends the choice as the next message, exactly as answering from the
  # conversation does. Nothing is written to `answers`: the transcript is already the record.
  def handle_event("chat:answer", %{"chat" => id, "choice" => choice}, socket) do
    # The id comes off the wire, so the guard has to resolve it: `Operator.send_chat/4` takes
    # the chat's own project and refuses a non-member. This handler was the hole a review found —
    # the queue correctly hid the item, and hiding it was the only thing stopping anyone.
    chat = Conversations.get!(id)

    case Operator.send_chat(chat, socket.assigns.current_scope.user, choice) do
      {:ok, _event} ->
        {:noreply, load(socket)}

      # The queue lists only live conversations, so this is the race rather than the rule: it
      # ended between the page rendering and the tap. Reloading drops the item.
      {:error, :not_live} ->
        {:noreply,
         socket
         |> put_flash(:error, "That conversation stopped before the answer reached it.")
         |> load()}

      # Not reachable from a page that rendered honestly — the queue never listed it. Handled
      # rather than left to crash, because the refusal is the point and a crash loses it.
      {:error, :forbidden} ->
        {:noreply, socket |> put_flash(:error, "That conversation is not yours.") |> load()}
    end
  end

  @impl true
  def handle_event("push:subscribe", %{"endpoint" => _} = subscription, socket) do
    case Push.subscribe(socket.assigns.current_scope.user, subscription) do
      {:ok, _} ->
        {:noreply,
         put_flash(socket, :info, "This browser will be notified of blocking questions.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save the subscription.")}
    end
  end

  def handle_event("push:unsubscribe", %{"endpoint" => endpoint}, socket) do
    Push.unsubscribe(socket.assigns.current_scope.user, endpoint)
    {:noreply, put_flash(socket, :info, "Notifications off for this browser.")}
  end

  def handle_event("push:error", %{"reason" => reason}, socket) do
    {:noreply, put_flash(socket, :error, "Notifications unavailable: #{reason}")}
  end

  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      :unknown -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:queue}
      queue_count={@decisions}
      measure="34rem"
    >
      <header class="flex items-baseline justify-between gap-4">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Queue</h1>
        <div class="flex items-center gap-3">
          <span :if={@items != []} class="font-mono text-[12.5px] opacity-60">
            {@decisions} {noun(@decisions, "decision")} · {length(@items)} {noun(
              length(@items),
              "item"
            )}
          </span>
          <button
            :if={@push_key}
            id="push-toggle"
            type="button"
            class="flex min-h-[46px] items-center gap-2 px-2 text-sm opacity-60 hover:opacity-100"
            phx-hook="PushSubscribe"
            data-vapid-key={@push_key}
          >
            <.icon name="hero-bell" class="size-4" /> <span data-label>Notify me</span>
          </button>
        </div>
      </header>

      <section class="mt-6 flex flex-col">
        <article
          :for={item <- @items}
          id={item_id(item)}
          class="flex flex-col gap-[11px] border-t border-base-300 py-[18px]"
        >
          <%!-- The header and the sentence are one target, and they stop where the answer
                affordance begins. A whole-card link would put an answer row inside a link and
                make "read this" and "approve this" the same gesture — see docs/design/ui.md
                § The affordance rule. --%>
          <.link navigate={destination(item)} class="flex flex-col gap-[11px]">
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-center gap-2">
                <.mark kind={item.kind} />
                <span class="font-mono text-[11px] tracking-[.14em] uppercase opacity-70">
                  {kind_label(item)}
                </span>
              </div>
              <span class="font-mono text-[17px] leading-none opacity-70">
                {Format.ago(item.since, @now)}
              </span>
            </div>

            <p class="text-xl/[1.3] font-medium -tracking-[.01em]">{sentence(item)}</p>
          </.link>

          <.questions_affordance :if={item.kind == :questions} item={item} />

          <.approval_card
            :if={item.kind == :approval}
            ticket={item.ticket}
            pending={item.detail}
            approve={item.approve}
          />

          <%!-- A link, never an answer row: answering never navigates, and the answer row is the
                one shape in the queue that commits something. --%>
          <.link
            :if={reviewable?(item)}
            navigate={~p"/tickets/#{item.project}/#{item.ticket.number}/review"}
            class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            Read the change first ›
          </.link>

          <.transition_card
            :if={item.kind in [:stuck, :review]}
            ticket={item.ticket}
            transitions={transitions(item)}
          />

          <.chat_answer :if={item.kind == :chat} item={item} />

          <.identifiers
            :if={item.ticket}
            project={item.project}
            ticket={item.ticket}
            topology={item.topology}
            artifact={item.version && item.version.artifact.name}
            version={item.version && item.version.version}
          />
        </article>
      </section>

      <section :if={@digest != []} class="mt-8 border-t border-base-300 pt-5">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
          Not waiting on you
        </h2>
        <ul class="mt-3 flex flex-col gap-2">
          <li :for={item <- @digest} class="flex items-baseline justify-between gap-3 text-sm">
            <.link navigate={destination(item)} class="truncate opacity-80 hover:opacity-100">
              {sentence(item)}
            </.link>
            <span class="shrink-0 font-mono text-[12.5px] opacity-50">
              {Format.ago(item.since, @now)}
            </span>
          </li>
        </ul>
      </section>

      <section class="mt-8 border-t border-base-300 pt-5" id="queue-end">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-success">End of queue</h2>
        <p class="mt-2 text-sm/[1.55]">{closing(@items)}</p>
      </section>
    </Layouts.app>
    """
  end

  # Three marks carry every kind, so the vocabulary scales without becoming a colour quiz. The
  # kind is named in words beside the mark.
  attr :kind, :atom, required: true

  defp destination(%{kind: :chat} = item), do: ~p"/chats/#{item.detail.chat_id}"
  defp destination(item), do: ~p"/tickets/#{item.project}/#{item.ticket.number}"

  # A chat question gets the same answer rows a job's does, so it can be answered without
  # opening the conversation — the difference between answering from a phone and not.
  attr :item, :map, required: true

  defp chat_answer(assigns) do
    ~H"""
    <div :if={@item.detail.question} class="flex flex-col gap-2">
      <.answer_row
        :for={option <- @item.detail.question.options}
        phx-click="chat:answer"
        phx-value-chat={@item.detail.chat_id}
        phx-value-choice={option}
      >
        {option}
      </.answer_row>
    </div>

    <div :if={is_nil(@item.detail.question)} class="font-mono text-[12.5px] opacity-60">
      <.link navigate={~p"/chats/#{@item.detail.chat_id}"} class="hover:opacity-100">
        Open the conversation ›
      </.link>
    </div>
    """
  end

  defp mark(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "mt-0.5 inline-block size-2 shrink-0",
        @kind in [:questions, :stuck] && "rotate-45 bg-accent",
        @kind == :approval && "border border-primary",
        @kind == :review && "rounded-full border border-success"
      ]}
    />
    """
  end

  attr :item, :map, required: true

  defp questions_affordance(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <.answer_row
        :if={length(@item.questions) > 1 and Enum.all?(@item.questions, & &1.default)}
        phx-click="answer_all"
        phx-disable-with="Sending…"
        phx-value-ticket={@item.ticket.id}
        phx-value-version={@item.version.id}
      >
        Accept all {length(@item.questions)} recommendations
      </.answer_row>

      <.question_card
        :for={question <- @item.questions}
        question={question}
        ticket_id={@item.ticket.id}
      />
    </div>
    """
  end

  defp item_id(%{kind: :questions} = item), do: "item-questions-#{item.version.id}"
  defp item_id(%{kind: :chat} = item), do: "item-chat-#{item.detail.chat_id}"
  defp item_id(item), do: "item-#{item.kind}-#{item.ticket.id}"

  # A decision that pins the changeset is a merge decision, and a merge decision is not one the
  # operator should take from a one-line summary. It arrives either as a pending approval or, when
  # the workflow leaves the ticket resting in a human state, as the transition out of it.
  defp reviewable?(%{kind: :approval, approve: approve}),
    do: Enum.any?(approve, fn {name, _version} -> name == Workflow.changeset_artifact() end)

  defp reviewable?(%{kind: kind, detail: detail}) when kind in [:review, :stuck],
    do: Map.get(detail, :reviewable, false)

  defp reviewable?(_item), do: false

  defp kind_label(%{kind: :questions, questions: questions}) do
    blocking = Enum.count(questions, & &1.blocking)

    if blocking > 0,
      do: "#{blocking} blocking #{noun(blocking, "question")}",
      else: "#{length(questions)} #{noun(length(questions), "question")}"
  end

  defp kind_label(%{kind: :chat}), do: "conversation"
  defp kind_label(%{kind: :approval}), do: "approval"
  defp kind_label(%{kind: :stuck}), do: "stuck"
  defp kind_label(%{kind: :review}), do: "review ready"

  defp sentence(%{kind: :questions, questions: [question]}), do: question.text

  defp sentence(%{kind: :questions} = item),
    do:
      "#{length(item.questions)} questions about #{item.version.artifact.name} v#{item.version.version}."

  # What it said, not what it is: a conversation waiting on you is waiting with its last reply
  # on screen, and that reply is the thing you are deciding about.
  defp sentence(%{kind: :chat} = item) do
    case item.detail.question do
      nil -> first_line(item.detail.text)
      question -> question.text
    end
  end

  defp sentence(%{kind: :approval} = item),
    do: "#{item.ticket.title} is ready to move to #{item.detail["to"]}."

  defp sentence(%{kind: :stuck} = item),
    do: "#{item.ticket.title} is stuck and needs a way forward."

  defp sentence(%{kind: :review} = item), do: "#{item.ticket.title} is waiting for your review."

  defp first_line(nil), do: "It is waiting for you."

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  defp closing([]), do: "Nothing needs you. Work continues without you."
  defp closing(_items), do: "That is everything waiting on you."

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"

  # Both kinds carry the states the operator may pick in the queue item itself, so the page
  # renders what the API serves rather than reading the workflow a second time.
  defp transitions(%{detail: %{transitions: transitions}}), do: transitions
  defp transitions(_item), do: []
end
