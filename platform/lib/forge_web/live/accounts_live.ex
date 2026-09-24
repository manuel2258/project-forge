defmodule ForgeWeb.AccountsLive do
  @moduledoc """
  The node admin's accounts page: who is waiting, who is in, and who may let others in.

  Approval is the perimeter — `docs/design/identity.md` § Approval — so this is the page where
  the perimeter is actually drawn, and it is the only surface `node_admin` unlocks. It grants no
  access to any project and shows none: a node admin governs accounts, not work.

  Pending accounts are first because they are the only rows that are waiting on the person
  reading, which is the same rule the queue follows.
  """

  use ForgeWeb, :live_view

  alias Forge.Accounts
  alias Forge.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Accounts") |> load()}
  end

  defp load(socket) do
    users = Accounts.list_users()
    {pending, decided} = Enum.split_with(users, &pending?/1)

    assign(socket, pending: pending, decided: decided, issuers: issuers(users))
  end

  # Where each account logs in from, for the row. It is the question a node admin is actually
  # answering when a pending account appears — an address proves nothing, and an account
  # provisioned by an OIDC login is one an issuer let through rather than one somebody made on
  # the host. `docs/design/identity.md` § Identity is `(issuer, subject)`, never email.
  defp issuers(users), do: Accounts.issuers_by_user(users)

  # A host-made account has none, and says so rather than looking like a row with missing data.
  attr :issuers, :list, required: true

  defp origin(assigns) do
    ~H"""
    <span class="font-mono text-[11.5px] opacity-60">
      {if @issuers == [], do: "local", else: Enum.join(@issuers, " ")}
    </span>
    """
  end

  defp pending?(%User{approved_at: nil, suspended_at: nil}), do: true
  defp pending?(%User{}), do: false

  @impl true
  def handle_event("approve", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.approve_user/2)

  def handle_event("suspend", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.suspend_user/2)

  def handle_event("reinstate", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.reinstate_user/2)

  def handle_event("promote", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.set_node_admin(&1, &2, true))

  def handle_event("demote", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.set_node_admin(&1, &2, false))

  # Only offered on a waiting row, and `delete_unapproved_user/2` refuses an approved one
  # regardless — the button is not the guard. `data-confirm` is because this is the one
  # governance action that cannot be undone.
  def handle_event("delete", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.delete_unapproved_user/2)

  # The guard is the context function, not this callback: `set_node_admin/3` refuses the last
  # node admin, and the button below is hidden for the same row. Hiding a button is cosmetics.
  defp act(socket, id, fun) do
    case Accounts.get_user(id) do
      nil -> {:noreply, put_flash(socket, :error, "No such account.")}
      user -> decide(socket, user, fun)
    end
  end

  defp decide(socket, user, fun) do
    case fun.(user, socket.assigns.current_scope.user) do
      {:ok, _user} ->
        {:noreply, load(socket)}

      {:error, :last_node_admin} ->
        {:noreply, put_flash(socket, :error, "That is the only administrator left.")}

      {:error, :approved} ->
        {:noreply, put_flash(socket, :error, "An approved account cannot be deleted.")}

      # What `on_delete: :restrict` answered. Worth its own message: the operator's next question
      # is always "why not", and "it has a history" is the answer.
      {:error, :has_history} ->
        {:noreply,
         put_flash(socket, :error, "That account has a history on this node and stays.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That did not work.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} measure="48rem">
      <header class="flex flex-wrap items-baseline justify-between gap-3">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Accounts</h1>
        <span :if={@pending != []} class="font-mono text-[12.5px] opacity-60">
          {length(@pending)} waiting
        </span>
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        Approving an account lets it in and lets it create projects. It does not give it access to
        any project of yours.
      </p>

      <section :if={@pending != []} class="mt-6">
        <h2 class="text-sm font-medium opacity-70">Waiting</h2>
        <ul class="mt-2 divide-y divide-base-300 border-y border-base-300">
          <li :for={user <- @pending} class="flex flex-wrap items-center gap-3 py-3">
            <span class="font-mono text-[13px]">{user.email}</span>
            <.origin issuers={Map.get(@issuers, user.id, [])} />
            <div class="ml-auto flex gap-2">
              <.account_button id={user.id} event="approve">Approve</.account_button>
              <.account_button id={user.id} event="suspend">Refuse</.account_button>
              <.account_button
                id={user.id}
                event="delete"
                confirm={"Delete #{user.email}? This frees the address and cannot be undone."}
              >
                Delete
              </.account_button>
            </div>
          </li>
        </ul>
      </section>

      <section class="mt-6">
        <h2 class="text-sm font-medium opacity-70">Accounts</h2>
        <ul class="mt-2 divide-y divide-base-300 border-y border-base-300">
          <li :for={user <- @decided} class="flex flex-wrap items-center gap-3 py-3">
            <span class="font-mono text-[13px]">{user.email}</span>
            <.origin issuers={Map.get(@issuers, user.id, [])} />
            <span :if={user.node_admin} class="font-mono text-[11.5px] opacity-60">admin</span>
            <span :if={user.suspended_at} class="font-mono text-[11.5px] opacity-60">suspended</span>
            <div class="ml-auto flex gap-2">
              <.account_button :if={user.suspended_at} id={user.id} event="reinstate">
                Reinstate
              </.account_button>
              <.account_button :if={is_nil(user.suspended_at)} id={user.id} event="suspend">
                Suspend
              </.account_button>
              <.account_button :if={!user.node_admin} id={user.id} event="promote">
                Make admin
              </.account_button>
              <.account_button
                :if={user.node_admin and not last_admin?(@decided, user)}
                id={user.id}
                event="demote"
              >
                Remove admin
              </.account_button>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp last_admin?(users, %User{id: id}) do
    not Enum.any?(users, &(&1.node_admin and &1.id != id))
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :confirm, :string, default: nil
  slot :inner_block, required: true

  defp account_button(assigns) do
    ~H"""
    <button
      phx-click={@event}
      phx-value-id={@id}
      data-confirm={@confirm}
      class="min-h-[46px] rounded-field border border-base-300 px-3 text-sm hover:border-base-content/30"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
