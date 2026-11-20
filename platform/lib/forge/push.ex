defmodule Forge.Push do
  @moduledoc """
  Web push to the operator's browsers. Whatever starts waiting on a person is pushed as it does
  (`waiting/1`, fed by `Forge.Push.Watch` for tickets and by `chat_reply/1` for a conversation's
  turn); the rest goes into one daily digest. Enabled only when VAPID keys are configured.

  **What a device is told.** Every push carries its recipient's own `badge` (left out only when counting it fails), their queue button's
  figure when it is sent (`Forge.Queue.count/1`, computed per recipient inside the delivery task); an
  item's push also carries `item: true`, which marks its notification as one a device may tidy away
  once the item stops waiting. `tag/1` names a notification and `state/1` is the read a device makes
  to learn which tags still wait (`docs/design/ui.md` § The installed app).

  Delivery runs in a supervised task so a slow or failing push service never blocks the
  caller, and one bad subscription never prevents the others from being served.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.Jobs.Job
  alias Forge.Proposals
  alias Forge.Push.Subscription
  alias Forge.Queue
  alias Forge.Repo

  require Logger

  @doc "Whether push is configured (VAPID keys present)."
  @spec enabled?() :: boolean()
  def enabled?,
    do:
      is_binary(public_key()) and
        is_binary(Application.get_env(:web_push_elixir, :vapid_private_key))

  @doc "The VAPID public key the browser subscribes with."
  @spec public_key() :: String.t() | nil
  def public_key, do: Application.get_env(:web_push_elixir, :vapid_public_key)

  @doc "Stores a browser subscription as the browser produced it (`endpoint`, `keys`)."
  @spec subscribe(User.t(), map()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()} | {:error, :malformed}
  def subscribe(%User{id: user_id}, %{"endpoint" => endpoint, "keys" => %{} = keys}) do
    attrs = %{user_id: user_id, endpoint: endpoint, p256dh: keys["p256dh"], auth: keys["auth"]}

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :updated_at]},
      conflict_target: :endpoint,
      returning: true
    )
  end

  def subscribe(%User{}, _), do: {:error, :malformed}

  @spec unsubscribe(User.t(), String.t()) :: :ok
  def unsubscribe(%User{id: user_id}, endpoint) do
    Repo.delete_all(
      from s in Subscription, where: s.user_id == ^user_id and s.endpoint == ^endpoint
    )

    :ok
  end

  @spec subscriptions() :: [Subscription.t()]
  def subscriptions, do: Repo.all(from s in Subscription, order_by: s.inserted_at)

  @doc """
  The subscriptions of the people who are members of `project_id`.

  What waits is pushed to the phones that can answer it and no others — the push fan-out
  is a read like any other, and it was the one that leaked to every device on the node.
  See `docs/design/identity.md` § Read scoping is the half that leaks.
  """
  @spec subscriptions(String.t()) :: [Subscription.t()]
  def subscriptions(project_id) when is_binary(project_id) do
    Repo.all(
      from s in Subscription,
        join: m in Forge.Projects.Member,
        on: m.user_id == s.user_id,
        join: u in Forge.Accounts.User,
        on: u.id == s.user_id,
        where: m.project_id == ^project_id,
        # Suspension refuses sessions and tokens; a device that keeps receiving blocking
        # questions for projects the account can no longer open is the same access by another
        # route. See `docs/design/identity.md` § Approval.
        where: not is_nil(u.approved_at) and is_nil(u.suspended_at),
        order_by: s.inserted_at
    )
  end

  @doc """
  Pushes one queue item that has started waiting on a person, to the phones of the people in its
  project — or nothing, when `Forge.Queue.waiting?/1` says it waits on nobody.

  **The rule is the queue's, not a list kept beside it** (`docs/design/ui.md` § The phone): a
  blocking question, an approval, a stuck ticket, a ticket resting where only a person can move
  it, a conversation's reply, and a schedule that failed or switched itself off all push; an
  assumption does not, and a kind added to the queue
  later pushes or does not for the same reason. Each links to where it waits: a ticket's page,
  which opens on the view holding it, a conversation's Talk, or a schedule's row on the Workflow
  view (`Forge.Schedules` pushes it when it opens the item).

  Tagged per thing waiting, so a re-ask or a later reply replaces its notification instead of
  stacking another.
  """
  @spec waiting(Queue.item()) :: :ok
  def waiting(item) do
    if Queue.waiting?(item), do: deliver_item(item), else: :ok
  end

  defp deliver_item(%{project: project} = item) do
    {title, body, url} = describe(item)
    tag = tag(item)

    # `item: true` is what lets a device tidy this notification away once the item stops waiting
    # (`state/1`); the digest is not marked, so nothing tidies it.
    deliver(
      %{title: title, body: String.slice(body || "", 0, 200), url: url, tag: tag, item: true},
      ttl: 86_400,
      urgency: :high,
      topic: topic(tag),
      to: project.id
    )
  end

  @doc """
  The tag a queue item's notification carries: one per thing waiting, so a re-ask or a later reply
  replaces its notification instead of stacking another.

  **This is the only place a queue item's tag is built** (the digest's is the literal `"digest"`, and is
  never listed). `waiting/1` pushes with it and `state/1` lists the
  waiting items by it, and the device closes a notification whose tag is not listed — a second way
  of building a tag would be a guard on a different model from the thing it guards
  (`docs/design/ui.md` § The installed app).
  """
  @spec tag(Queue.item()) :: String.t()
  def tag(%{kind: :chat, detail: %{chat_id: chat_id}}), do: "chat-#{chat_id}"
  def tag(%{kind: :schedule, detail: detail}), do: "schedule-#{detail.id}"

  def tag(%{kind: :question, ticket: ticket, question: question}),
    do: "question-#{ticket.id}-#{question.key}"

  def tag(%{kind: kind, ticket: ticket}), do: "#{kind}-#{ticket.id}"

  @doc """
  What a device is told about its person's queue (`GET /push/waiting`): `count`, the queue
  button's figure (`Queue.count/2`, accounts waiting for a node admin included), and the `tags` of
  every item that waits on them by `Queue.waiting?/1`, none dropped however many there are.

  Read over the person's own queue and nobody else's: `Queue.items/1` is scoped by membership.
  """
  @spec state(User.t()) :: %{count: non_neg_integer(), tags: [String.t()]}
  def state(%User{} = user) do
    items = Queue.items(user)

    %{
      count: Queue.count(items, Queue.waiting_accounts(user)),
      # `uniq` is an equivalent mutant: no two waiting items share a tag today and a device holds the
      # list as a set, so a repeat would change nothing it does. It keeps the list honest to read.
      tags: items |> Enum.filter(&Queue.waiting?/1) |> Enum.map(&tag/1) |> Enum.uniq()
    }
  end

  defp describe(%{kind: :chat, project: project, detail: %{lost: true} = detail}) do
    {"Reply lost on #{project.name}", detail.text, "/chats/#{detail.chat_id}?tab=talk"}
  end

  defp describe(%{kind: :chat, project: project, detail: detail}) do
    {"Reply on #{project.name}", detail.text || "It replied.",
     "/chats/#{detail.chat_id}?tab=talk"}
  end

  # A schedule has no ticket: it opens on the Workflow view, at the schedule.
  defp describe(%{kind: :schedule, project: project, detail: detail}) do
    what =
      if detail.problem_kind == :switched_off, do: "switched off", else: "failed"

    {"Schedule #{what} on #{project.name}", "#{detail.name} — #{detail.reason}",
     ForgeWeb.SchedulesView.path(project, detail)}
  end

  defp describe(%{kind: kind, project: project, ticket: ticket} = item) do
    label = "#{project.name}##{ticket.number}"

    # The ticket itself: it opens on the view holding what waits (`docs/design/ui.md` § The ticket).
    url = "/tickets/#{project.name}/#{ticket.number}"

    case kind do
      :question ->
        {"Question on #{label}", item.question.text, url}

      :approval ->
        {"Approval on #{label}", "#{ticket.title} — to #{item.detail["to"]}", url}

      :stuck ->
        {"Stuck: #{label}", stuck_body(ticket, item.detail[:reason]), url}

      _review ->
        {"Waiting on you: #{label}", "#{ticket.title} — in #{ticket.state}", url}
    end
  end

  defp stuck_body(ticket, reason) when is_binary(reason), do: "#{ticket.title} — #{reason}"
  defp stuck_body(ticket, _reason), do: ticket.title

  @doc """
  Pushes a conversation's completed reply, if its conversation is now waiting on a person.

  **Every completed reply pushes**, not every token: a turn ending is the event.
  `docs/decisions.md`'s push rule names a conversation's reply among what waits on a human — a
  reply to a question you asked is the same shape of thing as an answer you are owed, and the
  product's premise is that you asked it from a train platform. See `docs/design/conversations.md`
  § In the queue, and on the phone. It goes through `waiting/1`, so it is the queue's item and
  the queue's rule.
  """
  @spec chat_reply(Job.t()) :: :ok
  def chat_reply(%Job{kind: :chat} = chat) do
    chat |> Queue.for_chat() |> Enum.each(&waiting/1)
  end

  @doc """
  Pushes a step conversation whose reply was lost with its machine, when it is now waiting on a
  person (`docs/design/conversations.md` § Lifetime): the person's message was the last word, or
  the agent's reply was cut off before its turn ended, and its machine went before a reply came, so
  the ticket is a queue item and the project is told, as for anything that starts waiting on a person.

  **Only the lost item pushes.** A machine lost after the agent had already replied leaves the
  item the reply made, which pushed when it was made and has not changed; an ordinary
  conversation is in no queue, so there is nothing to push. A machine released by the idle
  timeout or the spend cap pushes nothing at all — it does not come through here
  (`Forge.Conversations.ended/4`). Nor does a held ticket's: `Queue.for_chat/1` has no item for it.
  """
  @spec lost_reply(Job.t()) :: :ok
  def lost_reply(%Job{kind: :chat} = chat) do
    chat
    |> Queue.for_chat()
    |> Enum.filter(&match?(%{detail: %{lost: true}}, &1))
    |> Enum.each(&waiting/1)
  end

  @doc """
  Pushes one summary of the queue, if there is anything to say.

  Open ticket proposals are counted here and nowhere else. They are not queue items — a
  proposal blocks nothing, and `docs/decisions.md` puts everything that is not a blocking
  question in the digest — but a proposal nobody is ever told about is a proposal nobody
  decides, and the backlog an agent reads keeps offering it back.

  Open non-blocking questions are counted apart for the same reason: they are in the queue as
  `:assumption`, and waiting on nobody (`docs/design/job-prompt.md` § Non-blocking questions).
  Neither is ever in the title's "waiting on you".
  """
  @spec digest() :: :ok | :empty
  def digest do
    Repo.all(
      from s in Subscription,
        join: u in Forge.Accounts.User,
        on: u.id == s.user_id,
        where: not is_nil(u.approved_at) and is_nil(u.suspended_at),
        distinct: true,
        select: s.user_id
    )
    |> Enum.map(&Forge.Accounts.get_user!/1)
    |> Enum.map(&digest_for/1)
    |> Enum.any?(&(&1 == :ok))
    |> if(do: :ok, else: :empty)
  end

  # One digest per reader, over their own projects. A single node-wide summary would tell
  # everybody how many decisions are open somewhere they cannot go, which is both a leak and a
  # number nobody can act on.
  defp digest_for(user) do
    {waiting, assumed} = user |> Queue.items() |> Enum.split_with(&Queue.waiting?/1)
    apart = %{assumed: length(assumed), proposed: Proposals.open_count(user)}

    case {waiting, apart} do
      {[], %{assumed: 0, proposed: 0}} ->
        :empty

      {waiting, apart} ->
        deliver(
          %{
            title: digest_title(length(waiting), apart),
            body: digest_body(waiting, apart),
            url: "/",
            tag: "digest"
          },
          ttl: 43_200,
          topic: "digest",
          subscriptions: for_user(user)
        )
    end
  end

  defp for_user(%User{id: user_id}) do
    Repo.all(from s in Subscription, where: s.user_id == ^user_id, order_by: s.inserted_at)
  end

  # The title says what is *waiting*, which assumptions and proposals are not. A count that
  # folded them in would make the queue's promise — reach the end and be done — read as broken by
  # things that never belonged to it.
  defp digest_title(0, apart), do: "forge: " <> Enum.join(counted_apart(apart), ", ")
  defp digest_title(waiting, _apart), do: "forge: #{waiting} waiting on you"

  defp digest_body(waiting, apart) do
    counts =
      waiting
      |> Enum.frequencies_by(& &1.kind)
      |> Enum.map(fn {k, n} -> "#{n} #{k}" end)

    Enum.join(counts ++ counted_apart(apart), ", ")
  end

  defp counted_apart(%{assumed: assumed, proposed: proposed}) do
    for {n, word} <- [{assumed, "assumed"}, {proposed, "proposed"}], n > 0, do: "#{n} #{word}"
  end

  @doc "Waits for in-flight deliveries to finish. For tests."
  @spec flush() :: :ok
  def flush do
    Forge.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  # Sends to every subscription in the background, dropping the ones the push service says
  # are gone. A subscription whose delivery raises is logged and skipped, not retried.
  #
  # **Each recipient's payload carries their own `badge`**, their queue button's figure at the
  # moment of sending, computed here per person and not once for a project: two members whose
  # queues differ are sent different numbers (`docs/design/ui.md` § The installed app).
  defp deliver(payload, opts) do
    if enabled?() do
      # `:to` is a project: only its members' devices. Without it this is a node-wide message —
      # the digest, which is assembled per reader elsewhere, and the flush in the test helper.
      subscriptions =
        cond do
          given = Keyword.get(opts, :subscriptions) -> given
          project_id = Keyword.get(opts, :to) -> subscriptions(project_id)
          true -> subscriptions()
        end

      {:ok, _pid} =
        Task.Supervisor.start_child(Forge.TaskSupervisor, fn ->
          subscriptions
          |> Enum.group_by(& &1.user_id)
          |> Enum.each(&deliver_to_user(&1, payload, opts))
        end)
    end

    :ok
  end

  defp deliver_to_user({user_id, subscriptions}, payload, opts) do
    json = payload |> with_badge(user_id) |> Jason.encode!()
    Enum.each(subscriptions, &deliver_one(&1, json, opts))
  end

  # A count that cannot be read must not stop the push: it still shows its notification, which is
  # the part a phone insists on, and the badge is set by the next push or opening instead.
  # **Nothing is logged here**: the change adds no log line (`docs/design/ui.md` § The installed app),
  # and a count that cannot be read is no more than a push without a figure.
  defp with_badge(payload, user_id) do
    Map.put(payload, :badge, counter().(Forge.Accounts.get_user!(user_id)))
  rescue
    _error -> payload
  end

  defp deliver_one(subscription, json, opts) do
    case sender().deliver(Subscription.to_json(subscription), json, opts) do
      :ok ->
        now = DateTime.utc_now(:second)

        Repo.update_all(from(s in Subscription, where: s.id == ^subscription.id),
          set: [last_sent_at: now]
        )

      {:error, :expired} ->
        Repo.delete_all(from s in Subscription, where: s.id == ^subscription.id)

      {:error, reason} ->
        Logger.warning("push to #{subscription.endpoint} failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.error(
        "push to #{subscription.endpoint} raised: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  # The push service collapses queued messages with the same topic; topics are at most 32
  # URL-safe characters, so hash the tag.
  defp topic(tag) do
    :sha256 |> :crypto.hash(tag) |> Base.url_encode64(padding: false) |> binary_part(0, 32)
  end

  # The queue button's figure for a person. A seam, like `sender/0`, so a test can make it raise.
  defp counter,
    do: Application.get_env(:forge, __MODULE__, [])[:counter] || (&Queue.count/1)

  defp sender,
    do: Application.get_env(:forge, __MODULE__, [])[:sender] || Forge.Push.Sender.WebPush
end
