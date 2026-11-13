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
  alias ForgeWeb.{Format, SignIn}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Accounts", refused: nil) |> load()}
  end

  defp load(socket) do
    users = Accounts.list_users()
    {pending, decided} = Enum.split_with(users, &pending?/1)

    assign(socket,
      pending: pending,
      decided: decided,
      identities: Accounts.identities_by_user(users),
      count: length(users)
    )
  end

  # How each account signs in, for the row. It is the question a node admin is actually
  # answering when a pending account appears — an address proves nothing, and an account
  # provisioned by an OIDC login is one an issuer let through rather than one somebody made on
  # the host. `docs/design/identity.md` § Identity is `(issuer, subject)`, never email, so the row
  # draws the pair: the issuer by its provider's name and the subject as the issuer sent it — in
  # the words You uses for the same account (`ForgeWeb.SignIn.ways/2`), so a host-made account is
  # `password` or `email link` on both pages, never `local` on one (UX pass, D20).
  attr :user, :map, required: true
  attr :identities, :list, required: true

  defp identities(assigns) do
    ~H"""
    <p id={"account-#{@user.id}-identities"} class="account-identities">
      <span :for={way <- SignIn.ways(@user, @identities)} class="account-identity">{way}</span>
    </p>
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
  # regardless — the button is not the guard. It is asked in place because this is the one
  # governance action that cannot be undone.
  def handle_event("delete", %{"id" => id}, socket),
    do: act(socket, id, &Accounts.delete_unapproved_user/2)

  # The guard is the context function, not this callback: `set_node_admin/3` refuses the last
  # node admin, and the button below is hidden for the same row. Hiding a button is cosmetics.
  defp act(socket, id, fun) do
    case Accounts.get_user(id) do
      nil -> {:noreply, refuse(socket, id, "No such account.")}
      user -> decide(socket, user, fun)
    end
  end

  defp decide(socket, user, fun) do
    case fun.(user, socket.assigns.current_scope.user) do
      {:ok, _user} ->
        {:noreply, socket |> assign(refused: nil) |> load()}

      {:error, :last_node_admin} ->
        {:noreply, refuse(socket, user.id, "That is the only administrator left.")}

      {:error, :self} ->
        {:noreply, refuse(socket, user.id, "You cannot suspend your own account.")}

      # The actor, read again at the act, is no admin who can act: suspended or demoted since this
      # page was opened (`Forge.Accounts`, review fixes 7, H1).
      {:error, :forbidden} ->
        {:noreply, refuse(socket, user.id, "You can no longer govern accounts.")}

      {:error, :approved} ->
        {:noreply, refuse(socket, user.id, "An approved account cannot be deleted.")}

      # What `on_delete: :restrict` answered. Worth its own message: the operator's next question
      # is always "why not", and "it has a history" is the answer.
      {:error, :has_history} ->
        {:noreply, refuse(socket, user.id, "That account has a history on this node and stays.")}

      {:error, _reason} ->
        {:noreply, refuse(socket, user.id, "That did not work.")}
    end
  end

  # Said in the row whose button was pressed (`docs/design/ui.md` § Errors stay where you acted),
  # or above the lists when that row is not drawn — an account gone since the page was.
  defp refuse(socket, id, text), do: socket |> assign(refused: {id, text}) |> load()

  defp refused_here(refused, id), do: match?({^id, _}, refused)

  defp stray?(nil, _users), do: false
  defp stray?({id, _}, users), do: not Enum.any?(users, &(&1.id == id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      section="Accounts"
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Accounts"
      subline={"#{length(@pending)} waiting · #{@count} #{noun(@count)}"}
      measure="40rem"
    >
      <p class="account-lede">
        Approving an account lets it in and lets it create projects. It does not give it access to
        any project of yours.
      </p>

      <.error_note :if={stray?(@refused, @pending ++ @decided)} id="accounts-refused">
        {elem(@refused, 1)}
      </.error_note>

      <section :if={@pending != []} id="accounts-waiting">
        <.eyebrow tone="accent">Waiting</.eyebrow>
        <p id="accounts-waiting-hint" class="account-hint">
          Refuse keeps the address blocked; Delete frees it to sign up again.
        </p>
        <ul class="account-list">
          <li :for={user <- @pending} id={"account-#{user.id}"} class="account-row">
            <div class="account-head">
              <span class="account-email">{user.email}</span>
              <span class="account-meta">{Format.ago(user.inserted_at)}</span>
            </div>
            <.identities user={user} identities={Map.get(@identities, user.id, [])} />
            <div class="account-actions">
              <%!-- An outline, not a primary: two waiting rows were two primaries side by side, and
                    the decision is reached from the queue's item (UX pass, A23). --%>
              <.account_button id={user.id} event="approve" variant="outline">
                Approve
              </.account_button>
              <.account_button id={user.id} event="suspend">Refuse</.account_button>
              <.account_button
                id={user.id}
                event="delete"
                act="Delete it"
                confirm={"Delete #{user.email}? This frees the address and cannot be undone."}
                label="Delete"
              />
            </div>
            <.error_note :if={refused_here(@refused, user.id)} id={"refused-#{user.id}"}>
              {elem(@refused, 1)}
            </.error_note>
          </li>
        </ul>
      </section>

      <section id="accounts-decided">
        <.eyebrow>Accounts</.eyebrow>
        <ul class="account-list">
          <li :for={user <- @decided} id={"account-#{user.id}"} class="account-row">
            <div class="account-head">
              <span class="account-email">{user.email}</span>
              <span class="account-meta">{standing(user, @current_scope.user)}</span>
            </div>
            <.identities user={user} identities={Map.get(@identities, user.id, [])} />
            <div class="account-actions">
              <.account_button :if={user.suspended_at} id={user.id} event="reinstate">
                Reinstate
              </.account_button>
              <%!-- Not on your own row: `suspend_user/2` refuses it, and the page does not offer
                    what would sign you out of the only place it can be undone. --%>
              <.account_button
                :if={is_nil(user.suspended_at) and user.id != @current_scope.user.id}
                id={user.id}
                event="suspend"
                act="Suspend it"
                confirm={"Suspend #{user.email}? They are signed out everywhere and cannot sign in until reinstated."}
                label="Suspend"
              />
              <.account_button
                :if={!user.node_admin}
                id={user.id}
                event="promote"
                act="Make them admin"
                tone="neutral"
                confirm={"Make #{user.email} a node admin? They can approve, suspend and promote anyone."}
                label="Make admin"
              />
              <%!-- On your own row it takes away this page, so it is asked first (review fixes 7,
                    M1). Offered only while another admin who can act is left: the rule
                    `set_node_admin/3` refuses by. --%>
              <.account_button
                :if={
                  user.node_admin and user.id == @current_scope.user.id and
                    not last_admin?(@decided, user)
                }
                id={user.id}
                event="demote"
                act="Remove mine"
                tone="neutral"
                confirm="Remove your own admin? You can no longer approve, suspend or promote anyone, and only another admin can give it back."
                label="Remove admin"
              />
              <.account_button
                :if={
                  user.node_admin and user.id != @current_scope.user.id and
                    not last_admin?(@decided, user)
                }
                id={user.id}
                event="demote"
              >
                Remove admin
              </.account_button>
            </div>
            <.error_note :if={refused_here(@refused, user.id)} id={"refused-#{user.id}"}>
              {elem(@refused, 1)}
            </.error_note>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  # What sits beside a decided account's address: `admin`, `you`, and how long ago a suspended
  # one was suspended.
  defp standing(user, me) do
    [
      user.node_admin && "admin",
      user.id == me.id && "you",
      user.suspended_at && "suspended #{Format.lasted(user.suspended_at)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp noun(1), do: "account"
  defp noun(_count), do: "accounts"

  # The page's copy of `Forge.Accounts`' rule, for hiding the button only: whether another admin
  # who can act — the flag and `User.active?/1` — is left. The context is the guard.
  defp last_admin?(users, %User{id: id}) do
    not Enum.any?(users, &(&1.node_admin and User.active?(&1) and &1.id != id))
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :confirm, :string, default: nil, doc: "asked in place first (`ui.md` § The confirm)"
  attr :act, :string, default: nil, doc: "the confirming button's words"
  attr :label, :string, default: nil, doc: "the trigger's words, with a confirm"
  attr :tone, :string, default: "danger"
  attr :variant, :string, default: "secondary"
  slot :inner_block

  defp account_button(%{confirm: sentence} = assigns) when is_binary(sentence) do
    ~H"""
    <.confirm
      id={"#{@event}-#{@id}"}
      label={@label}
      act={@act}
      sentence={@confirm}
      tone={@tone}
      size="md"
      class="ui-confirm--inline"
      phx-click={@event}
      phx-value-id={@id}
    />
    """
  end

  defp account_button(assigns) do
    ~H"""
    <.button variant={@variant} size="md" phx-click={@event} phx-value-id={@id}>
      {render_slot(@inner_block)}
    </.button>
    """
  end
end
