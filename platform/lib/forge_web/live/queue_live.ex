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

  Beneath the decisions, before the end, is what is **not waiting on you**: the questions agents
  did not stop for, as lines that lead to their tickets. They count towards nothing on this page
  — `docs/design/ui.md` § Not waiting on you. One asked in the same document as a blocking
  question is in that document's form instead, optional (§ Answering questions).
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components
  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1]

  alias Forge.{Artifacts, Events, Push, Queue, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board
  alias ForgeWeb.Operator.Drafts
  alias ForgeWeb.Operator.QuestionForm

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: "Queue",
       push_key: Push.enabled?() && Push.public_key(),
       forms: QuestionForm.init(),
       drafts: Drafts.init()
     )
     |> load()}
  end

  # The decisions are grouped and counted; the assumptions are the digest beneath them, in the
  # order `Forge.Queue` gives them, and count towards nothing — see docs/design/ui.md § Not
  # waiting on you. An assumption asked in the same document as a blocking question joins that
  # question's form instead, optional, because it was asked in the same breath
  # (docs/design/ui.md § Answering questions).
  defp load(socket) do
    {waiting, assumed} =
      Queue.items(socket.assigns.current_scope.user)
      |> Enum.map(&Map.put(&1, :project, &1.project.name))
      |> Enum.split_with(&Queue.waiting?/1)

    {joined, digest} =
      waiting
      |> Enum.filter(&(&1.kind == :question))
      |> QuestionForm.join_assumed(assumed, & &1.question.artifact_version_id)

    items = (waiting ++ joined) |> group() |> Enum.map(&decorate/1)

    assign(socket,
      items: items,
      digest: digest,
      decisions: Enum.sum(Enum.map(items, & &1.decisions)),
      now: DateTime.utc_now()
    )
  end

  # One job, stopped, against one artifact version, carrying N questions. Everything else is
  # already one interruption on its own. `load/1` only passes an assumption here when a blocking
  # question shares its version, so every group holds at least one of those.
  defp group(items) do
    {questions, rest} = Enum.split_with(items, &(&1.kind in [:question, :assumption]))

    questions
    |> Enum.group_by(& &1.question.artifact_version_id)
    |> Enum.map(fn {_version_id, group} ->
      first = hd(group)

      %{
        kind: :questions,
        ticket: first.ticket,
        project: first.project,
        # When it started waiting, which the blocking questions say. Taking the assumptions too is
        # an equivalent mutant as documents are recorded: a version's questions share one insert.
        since:
          group
          |> Enum.filter(&(&1.kind == :question))
          |> Enum.map(& &1.since)
          |> Enum.min(DateTime),
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
    |> Map.put_new(:questions, [])
    |> Map.put_new(:version, nil)
    |> put_approve()
  end

  defp decisions(%{kind: :questions} = item), do: Enum.count(item.questions, & &1.blocking)
  defp decisions(_item), do: 1

  defp put_approve(%{kind: :approval, ticket: ticket} = item) do
    approve =
      for name <- Forge.Engine.awaiting_approval(ticket),
          version = Artifacts.latest(ticket.id, name),
          do: pinned(item.project, ticket, name, version)

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

  # A chat's questions are answered here with the form its page draws, sent as one message by
  # `Operator.answer_chat/4` — which resolves the chat off the wire and refuses a non-member, the
  # hole a review once found in this page's answer buttons. Nothing is written to `answers`: the
  # transcript is already the record.
  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
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

      <section id="queue-decisions" class="mt-6 flex flex-col">
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

          <.question_form
            :if={item.kind == :questions}
            id={item.version.id}
            questions={item.questions}
            forms={@forms}
            submit="questions:send"
            hidden={[{"ticket", item.ticket.id}, {"version", item.version.id}]}
          />

          <.approval_card
            :if={item.kind == :approval}
            ticket={item.ticket}
            pending={item.detail}
            approve={item.approve}
            drafts={@drafts}
          />

          <%!-- A link, never an answer row: answering never navigates, and the answer row and the
                Send are the shapes in the queue that commit something. --%>
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

          <.retry_row :if={item.kind == :stuck and item.detail[:retry]} ticket={item.ticket} />

          <.chat_answer :if={item.kind == :chat} item={item} forms={@forms} />

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

      <%!-- Prose, not cards: no mark, no answer rows, no accent, because nothing here is waiting
            on anyone. Each line leads to its ticket, where the question is answered — see
            docs/design/ui.md § Not waiting on you. --%>
      <section :if={@digest != []} id="queue-digest" class="mt-8 border-t border-base-300 pt-5">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
          Not waiting on you
        </h2>
        <p class="mt-2 text-sm/[1.55] opacity-70">{digest_sentence(@digest)}</p>
        <ul class="mt-2 flex flex-col">
          <li :for={item <- @digest} id={"assumption-#{item.question.id}"}>
            <.link
              navigate={destination(item)}
              class="flex min-h-[46px] flex-col justify-center gap-0.5 py-2 opacity-80 hover:opacity-100"
            >
              <span class="flex items-baseline justify-between gap-3">
                <span class="text-sm/[1.55]">{item.question.text}</span>
                <span class="shrink-0 font-mono text-[12.5px] opacity-60">
                  {Format.ago(item.since, @now)}
                </span>
              </span>
              <span class="text-sm/[1.55] opacity-70">Assumed: {item.question.assumption}</span>
              <span class="font-mono text-[12.5px] opacity-60">
                {item.project}#{item.ticket.number}
              </span>
            </.link>
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

  # A chat's questions get the same form a job's do, so they can be answered without opening the
  # conversation — the difference between answering from a phone and not.
  attr :item, :map, required: true
  attr :forms, :map, required: true

  defp chat_answer(assigns) do
    ~H"""
    <.question_form
      :if={@item.detail.questions != []}
      id={"chat-#{@item.detail.chat_id}-#{@item.detail.reply}"}
      questions={@item.detail.questions}
      forms={@forms}
      submit="chat:questions:send"
      hidden={[{"chat", @item.detail.chat_id}, {"reply", @item.detail.reply}]}
    />

    <div :if={@item.detail.questions == []} class="font-mono text-[12.5px] opacity-60">
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

  defp item_id(%{kind: :questions} = item), do: "item-questions-#{item.version.id}"
  defp item_id(%{kind: :chat} = item), do: "item-chat-#{item.detail.chat_id}"
  defp item_id(item), do: "item-#{item.kind}-#{item.ticket.id}"

  # A decision that pins the changeset is a merge decision, and a merge decision is not one the
  # operator should take from a one-line summary. It arrives either as a pending approval or, when
  # the workflow leaves the ticket resting in a human state, as the transition out of it.
  defp reviewable?(%{kind: :approval, approve: approve}),
    do: Enum.any?(approve, &(&1.name == Workflow.changeset_artifact()))

  defp reviewable?(%{kind: kind, detail: detail}) when kind in [:review, :stuck],
    do: Map.get(detail, :reviewable, false)

  defp reviewable?(_item), do: false

  # Counted as blocking: an assumption in the same form is optional and waits on nobody, so it is
  # named apart rather than added to what is waiting.
  defp kind_label(%{kind: :questions, questions: questions}) do
    {blocking, optional} = Enum.split_with(questions, & &1.blocking)
    label = "#{length(blocking)} blocking #{noun(length(blocking), "question")}"
    if optional == [], do: label, else: "#{label} · #{length(optional)} optional"
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
    case item.detail.questions do
      [] -> first_line(item.detail.text)
      [question] -> question.text
      questions -> "#{length(questions)} questions: #{hd(questions).text}"
    end
  end

  defp sentence(%{kind: :approval} = item),
    do: "#{item.ticket.title} is ready to move to #{item.detail["to"]}."

  defp sentence(%{kind: :stuck, detail: %{reason: reason}} = item) when is_binary(reason),
    do: "#{item.ticket.title} is stuck: #{reason}."

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

  defp digest_sentence([_one]), do: "1 assumption was stated and work continued."

  defp digest_sentence(digest),
    do: "#{length(digest)} assumptions were stated and work continued."

  defp closing([]), do: "Nothing needs you. Work continues without you."
  defp closing(_items), do: "That is everything waiting on you."

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"

  # Both kinds carry the states the operator may pick in the queue item itself, so the page
  # renders what the API serves rather than reading the workflow a second time.
  defp transitions(%{detail: %{transitions: transitions}}), do: transitions
  defp transitions(_item), do: []
end
