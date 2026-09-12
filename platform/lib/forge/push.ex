defmodule Forge.Push do
  @moduledoc """
  Web push to the operator's browsers. Blocking questions are pushed as they appear;
  everything else goes into one daily digest. Enabled only when VAPID keys are configured.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.Projects
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
  @spec subscribe(User.t(), map(), String.t() | nil) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(%User{id: user_id}, %{"endpoint" => endpoint, "keys" => keys}, user_agent \\ nil) do
    attrs = %{
      user_id: user_id,
      endpoint: endpoint,
      p256dh: keys["p256dh"],
      auth: keys["auth"],
      user_agent: user_agent
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :p256dh, :auth, :user_agent, :updated_at]},
      conflict_target: :endpoint,
      returning: true
    )
  end

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

    deliver(%{
      title: "Question on #{label}",
      body: question.text,
      url: "/tickets/#{project.name}/#{ticket.number}",
      tag: "question-#{ticket.id}-#{question.key}"
    })
  end

  @doc "Pushes one summary of the queue, if it is not empty."
  @spec digest() :: :ok | :empty
  def digest do
    case Queue.items() do
      [] ->
        :empty

      items ->
        counts =
          items
          |> Enum.frequencies_by(& &1.kind)
          |> Enum.map_join(", ", fn {k, n} -> "#{n} #{k}" end)

        deliver(%{
          title: "forge: #{length(items)} waiting on you",
          body: counts,
          url: "/",
          tag: "digest"
        })
    end
  end

  # Sends to every subscription, dropping the ones the push service says are gone.
  defp deliver(payload) do
    if enabled?() do
      json = Jason.encode!(payload)
      Enum.each(subscriptions(), &deliver_one(&1, json))
    end

    :ok
  end

  defp deliver_one(subscription, json) do
    case sender().deliver(Subscription.to_json(subscription), json) do
      :ok ->
        now = DateTime.utc_now(:second)

        Repo.update_all(from(s in Subscription, where: s.id == ^subscription.id),
          set: [last_sent_at: now]
        )

      {:error, :expired} ->
        Repo.delete(subscription)

      {:error, reason} ->
        Logger.warning("push to #{subscription.endpoint} failed: #{inspect(reason)}")
    end
  end

  defp sender,
    do: Application.get_env(:forge, __MODULE__, [])[:sender] || Forge.Push.Sender.WebPush
end
