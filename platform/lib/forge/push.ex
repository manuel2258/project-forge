defmodule Forge.Push do
  @moduledoc """
  Web push to the operator's browsers. Blocking questions are pushed as they appear;
  everything else goes into one daily digest. Enabled only when VAPID keys are configured.

  Delivery runs in a supervised task so a slow or failing push service never blocks the
  caller, and one bad subscription never prevents the others from being served.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.Jobs.Job
  alias Forge.Projects
  alias Forge.Proposals
  alias Forge.Push.Subscription
  alias Forge.Queue
  alias Forge.Repo
  alias Forge.Tickets.Ticket

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

  @doc "Pushes one blocking question to every subscription."
  @spec blocking_question(Ticket.t(), map()) :: :ok
  def blocking_question(%Ticket{} = ticket, question) do
    project = Projects.get!(ticket.project_id)
    label = "#{project.name}##{ticket.number}"
    tag = "question-#{ticket.id}-#{question.key}"

    deliver(
      %{
        title: "Question on #{label}",
        body: question.text,
        url: "/tickets/#{project.name}/#{ticket.number}",
        tag: tag
      },
      ttl: 86_400,
      urgency: :high,
      topic: topic(tag)
    )
  end

  @doc """
  Pushes a conversation's completed reply.

  **Every completed reply pushes**, not every token: a turn ending is the event. This is a
  deliberate widening of `docs/decisions.md`'s "push notification for blocking questions,
  everything else digested" — a reply to a question you asked is the same shape of thing as an
  answer you are owed, and the product's premise is that you asked it from a train platform.
  See `docs/design/conversations.md` § In the queue, and on the phone.

  Tagged per conversation rather than per turn, so a chat you are having replaces its own
  notification instead of stacking one per exchange.
  """
  @spec chat_reply(Job.t(), String.t() | nil) :: :ok
  def chat_reply(%Job{kind: :chat} = chat, text) do
    project = Projects.get!(chat.project_id)
    tag = "chat-#{chat.id}"

    deliver(
      %{
        title: "Reply on #{project.name}",
        body: String.slice(text || "It replied.", 0, 200),
        url: "/chats/#{chat.id}",
        tag: tag
      },
      ttl: 86_400,
      urgency: :high,
      topic: topic(tag)
    )
  end

  @doc """
  Pushes one summary of the queue, if there is anything to say.

  Open ticket proposals are counted here and nowhere else. They are not queue items — a
  proposal blocks nothing, and `docs/decisions.md` puts everything that is not a blocking
  question in the digest — but a proposal nobody is ever told about is a proposal nobody
  decides, and the backlog an agent reads keeps offering it back.
  """
  @spec digest() :: :ok | :empty
  def digest do
    items = Queue.items()
    proposals = Proposals.open_count()

    case {items, proposals} do
      {[], 0} ->
        :empty

      {items, proposals} ->
        deliver(
          %{
            title: digest_title(length(items), proposals),
            body: digest_body(items, proposals),
            url: "/",
            tag: "digest"
          },
          ttl: 43_200,
          topic: "digest"
        )
    end
  end

  # The title says what is *waiting*, which proposals are not. A count that folded them in would
  # make the queue's promise — reach the end and be done — read as broken by things that never
  # belonged to it.
  defp digest_title(0, proposals), do: "forge: #{proposals} proposed"
  defp digest_title(waiting, _proposals), do: "forge: #{waiting} waiting on you"

  defp digest_body(items, proposals) do
    counts =
      items
      |> Enum.frequencies_by(& &1.kind)
      |> Enum.map(fn {k, n} -> "#{n} #{k}" end)

    counts = if proposals > 0, do: counts ++ ["#{proposals} proposed"], else: counts

    Enum.join(counts, ", ")
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
  defp deliver(payload, opts) do
    if enabled?() do
      json = Jason.encode!(payload)
      subscriptions = subscriptions()

      {:ok, _pid} =
        Task.Supervisor.start_child(Forge.TaskSupervisor, fn ->
          Enum.each(subscriptions, &deliver_one(&1, json, opts))
        end)
    end

    :ok
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

  defp sender,
    do: Application.get_env(:forge, __MODULE__, [])[:sender] || Forge.Push.Sender.WebPush
end
