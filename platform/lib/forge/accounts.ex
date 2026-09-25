defmodule Forge.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Forge.Accounts.{Identity, User, UserNotifier, UserToken}
  alias Forge.{Events, Repo}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  # Equivalent mutant *for authentication*, which is the only thing this decides: relaxing the
  # guard to `or` never authenticates anyone, because a non-binary password reaches
  # `User.valid_password?/2` and its second clause answers false after a dummy hash. It does
  # change which failure a non-binary argument produces — `FunctionClauseError` becomes nil, or
  # an `ArgumentError`, or a cast error, depending on which argument it was. No caller passes
  # one: every one is a form that sends strings. The first version of this comment claimed the
  # mutant changed nothing observable at all, which was wider than the truth.
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user, or nil.

  For ids that came off the wire: a page holding a client-supplied id must not raise for one
  that is well-formed and unknown.
  """
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(id) do
    Repo.get(User, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Forge.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Forge.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## API tokens

  @doc """
  Creates an API token for the user; returns the encoded token, shown once. Like session
  tokens, API tokens are deleted when the user's password or email changes.
  """
  def create_api_token(%User{} = user, name) when is_binary(name) do
    {encoded, user_token} = UserToken.build_api_token(user, name)
    Repo.insert!(user_token)
    encoded
  end

  @doc "The user behind an encoded API token, or nil."
  def get_user_by_api_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_api_token_query(token),
         %User{} = user <- Repo.one(query),
         # The API has no holding page to show a pending account, so it refuses one outright.
         # A session is gentler (see `get_user_by_session_token/1`); a token is not.
         true <- User.active?(user) do
      user
    else
      _ -> nil
    end
  end

  @doc "The user's API tokens: id, name and creation time. The token itself is not stored."
  def list_api_tokens(%User{id: user_id}) do
    Repo.all(
      from t in UserToken,
        where: t.user_id == ^user_id and t.context == "api",
        # Timestamps are second-resolution, so two tokens created in the same second tie and the
        # row order is whatever Postgres returns. Name breaks the tie so the listing is stable.
        order_by: [asc: t.inserted_at, asc: t.sent_to],
        select: %{id: t.id, name: t.sent_to, inserted_at: t.inserted_at}
    )
  end

  @doc "Deletes the user's API tokens with the given name; returns how many were deleted."
  def revoke_api_tokens(%User{id: user_id}, name) when is_binary(name) do
    {count, _} =
      Repo.delete_all(
        from t in UserToken,
          where: t.user_id == ^user_id and t.context == "api" and t.sent_to == ^name
      )

    count
  end

  @doc """
  Creates a confirmed, approved operator with a password, for the command line.

  This is the bootstrap: a node admin has to exist before anyone can be approved, and the first
  one cannot approve itself. Pass `node_admin: true` to seed one. An account made here is
  approved outright — the approval gate is for accounts that arrive through a login page, and
  whoever has a shell on the machine is past every gate there is.
  """
  @spec create_operator(String.t(), String.t(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_operator(email, password, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, user} <- register_user(%{email: email}),
           {:ok, user} <- user |> User.confirm_changeset() |> Repo.update(),
           {:ok, {user, _}} <- update_user_password(user, %{password: password}) do
        user
        |> Ecto.Changeset.change(
          approved_at: DateTime.utc_now(:second),
          node_admin: Keyword.get(opts, :node_admin, false)
        )
        |> Repo.update()
      end
    end)
  end

  ## External identities

  @doc """
  The user behind an identity, or nil. The key is the pair and never the address.

  `docs/design/identity.md` § Identity is `(issuer, subject)`, never email: a `subject` is stable
  only within its issuer, and two issuers asserting one address say nothing about each other.
  """
  @spec get_user_by_identity(String.t(), String.t()) :: User.t() | nil
  def get_user_by_identity(issuer, subject) when is_binary(issuer) and is_binary(subject) do
    Repo.one(
      from u in User,
        join: i in Identity,
        on: i.user_id == u.id,
        where: i.issuer == ^issuer and i.subject == ^subject
    )
  end

  @doc """
  Turns a verified identity into the user it is, creating one on first login.

  **A new account is pending** — § Approval is the
  perimeter and an issuer does not get to move it. `confirmed_at` is set because the issuer
  asserted the address and there is no confirmation email to send; that is not approval and
  grants nothing.

  **An address another account already holds is refused rather than adopted.** That is the whole
  of `{:error, :email_taken}` and it is the reason this cannot be a one-line upsert: adopting
  would mean any configured issuer could mint a `sub` with a node admin's address and become
  them. `link_identity/3` on the host is the deliberate join.
  """
  @spec log_in_with_identity(%{issuer: String.t(), subject: String.t(), email: String.t()}) ::
          {:ok, User.t()} | {:error, :email_taken | Ecto.Changeset.t()}
  def log_in_with_identity(%{issuer: issuer, subject: subject, email: email}) do
    case Repo.get_by(Identity, issuer: issuer, subject: subject) do
      %Identity{} = identity -> returning(identity, email)
      nil -> provision(issuer, subject, email)
    end
  end

  # A returning login refreshes what the issuer says now: the address is display-only, so it
  # follows the claim rather than pinning the one the account was made with.
  defp returning(%Identity{} = identity, email) do
    {:ok, _identity} =
      identity
      |> Identity.changeset(%{email: email, last_login_at: DateTime.utc_now(:second)})
      |> Repo.update()

    {:ok, Repo.get!(User, identity.user_id)}
  end

  defp provision(issuer, subject, email) do
    Repo.transact(fn ->
      with {:ok, user} <- register_user(%{email: email}),
           {:ok, user} <- user |> User.confirm_changeset() |> Repo.update(),
           {:ok, _identity} <- insert_identity(user, issuer, subject, email) do
        {:ok, user}
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, %Ecto.Changeset{errors: errors} = changeset} -> provision_error(errors, changeset)
    end
  end

  # An address already in use is the collision above and has its own answer; anything else is an
  # ordinary invalid changeset and is reported as one.
  #
  # **Both spellings of "taken", because there are two.** `User.email_changeset/3` runs
  # `unsafe_validate_unique`, which is what normally catches this and reports
  # `validation: :unsafe_unique`; the database constraint behind it reports
  # `constraint: :unique` and is what catches the race between that query and the insert.
  # Reading only one of them makes the answer depend on timing — the rare path falling through
  # to a changeset that no caller above has a message for.
  defp provision_error(errors, changeset) do
    case Keyword.get(errors, :email) do
      {_message, opts} ->
        if opts[:constraint] == :unique or opts[:validation] == :unsafe_unique,
          do: {:error, :email_taken},
          else: {:error, changeset}

      nil ->
        {:error, changeset}
    end
  end

  defp insert_identity(%User{} = user, issuer, subject, email) do
    %Identity{}
    |> Identity.changeset(%{
      user_id: user.id,
      issuer: issuer,
      subject: subject,
      email: email,
      last_login_at: DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Attaches an identity to an account that already exists, from the host.

  The one way an OIDC login and a local account become the same person. It is deliberately not
  something a login can do — see `log_in_with_identity/1` — and deliberately available to
  whoever has a shell, who is past every gate there is anyway.
  """
  @spec link_identity(User.t(), String.t(), String.t()) ::
          {:ok, Identity.t()} | {:error, :already_linked | Ecto.Changeset.t()}
  def link_identity(%User{} = user, issuer, subject) do
    case Repo.get_by(Identity, issuer: issuer, subject: subject) do
      %Identity{} -> {:error, :already_linked}
      nil -> insert_identity(user, issuer, subject, user.email)
    end
  end

  @doc "The identities an account logs in with, oldest first. The accounts page shows them."
  @spec list_identities(User.t()) :: [Identity.t()]
  def list_identities(%User{id: id}),
    do: Repo.all(from i in Identity, where: i.user_id == ^id, order_by: i.inserted_at)

  @doc """
  The issuers each of those accounts logs in from, keyed by user id, in one query.

  `ForgeWeb.AccountsLive` asked `list_identities/1` once per row, on mount and again after every
  approve, suspend and promote — a node with fifty accounts ran fifty queries to draw one column,
  four times over in a session. An account with no identity is present with an empty list, so the
  caller can tell "made on this host" from "not loaded".
  """
  @spec issuers_by_user([User.t()]) :: %{Ecto.UUID.t() => [String.t()]}
  def issuers_by_user(users) do
    ids = Enum.map(users, & &1.id)

    # **`where` is a bound on what is fetched, not on what is returned — an equivalent mutant.**
    # Removing it changes no answer, because `Map.new(ids, ...)` below reads only the ids asked
    # about and any extra rows are discarded. What it changes is that the node's every identity
    # crosses the wire to draw one page. Do not write a test asserting the output differs: it
    # does not, and such a test would pass against the unbounded query.
    rows =
      Repo.all(
        from i in Identity,
          where: i.user_id in ^ids,
          order_by: i.inserted_at,
          select: {i.user_id, i.issuer}
      )

    found = Enum.group_by(rows, &elem(&1, 0), &elem(&1, 1))

    Map.new(ids, fn id -> {id, found |> Map.get(id, []) |> Enum.uniq()} end)
  end

  ## Account governance

  @doc """
  The user a host-side command should act as, from an optional address.

  With an address, that user. Without one, the node's only admin — the single-operator case,
  which is every PoC node, where naming yourself on each command is friction for no decision.
  With more than one it refuses rather than guessing, because the answer decides who can reach
  a project afterwards.
  """
  @spec owner_for(String.t() | nil) ::
          {:ok, User.t()} | {:error, :unknown_user | :ambiguous_owner | :no_owner}
  def owner_for(email) when is_binary(email) do
    case get_user_by_email(email) do
      nil -> {:error, :unknown_user}
      user -> {:ok, user}
    end
  end

  def owner_for(nil) do
    case Repo.all(from u in User, where: u.node_admin == true, limit: 2) do
      [user] -> {:ok, user}
      [] -> {:error, :no_owner}
      _many -> {:error, :ambiguous_owner}
    end
  end

  @doc "Every user, oldest first. The node admin's accounts page."
  @spec list_users() :: [User.t()]
  def list_users, do: Repo.all(from u in User, order_by: u.inserted_at)

  @doc "Accounts waiting on a node admin, oldest first."
  @spec list_pending_users() :: [User.t()]
  def list_pending_users do
    Repo.all(
      from u in User,
        where: is_nil(u.approved_at) and is_nil(u.suspended_at),
        order_by: u.inserted_at
    )
  end

  @doc """
  Approves a pending account. Approval is the perimeter: everything behind it is permissive,
  so this is the decision that matters and it is audited like any other mutation.
  """
  @spec approve_user(User.t(), User.t() | :host) :: {:ok, User.t()} | {:error, term()}
  def approve_user(%User{} = user, by),
    do: govern(user, by, "user.approved", approved_at: DateTime.utc_now(:second))

  @doc """
  Suspends an account. Sessions and API tokens are refused from the next request.

  `approved_at` is deliberately left alone: reinstating is then one field rather than a second
  decision, and `User.active?/1` is what refuses the account meanwhile.
  """
  @spec suspend_user(User.t(), User.t()) :: {:ok, User.t()} | {:error, term()}
  def suspend_user(%User{} = user, %User{} = by),
    do: govern(user, by, "user.suspended", suspended_at: DateTime.utc_now(:second))

  @doc "Lifts a suspension."
  @spec reinstate_user(User.t(), User.t()) :: {:ok, User.t()} | {:error, term()}
  def reinstate_user(%User{} = user, %User{} = by),
    do: govern(user, by, "user.reinstated", suspended_at: nil)

  @doc """
  Grants or revokes the node admin flag.

  Revoking the last node admin is refused. It is the only account that can approve anyone, so a
  node with none is a node nobody can ever join again, and the fix would be a shell and a SQL
  statement.
  """
  @spec set_node_admin(User.t(), User.t(), boolean()) :: {:ok, User.t()} | {:error, term()}
  def set_node_admin(%User{} = user, %User{} = by, true),
    do: govern(user, by, "user.node_admin_granted", node_admin: true)

  def set_node_admin(%User{} = user, %User{} = by, false) do
    if last_node_admin?(user),
      do: {:error, :last_node_admin},
      else: govern(user, by, "user.node_admin_revoked", node_admin: false)
  end

  @doc """
  Deletes an account that has never been approved, freeing the address it holds.

  **This is the one governance action that cannot be undone**, and the one exception to the rule
  that users are never deleted (`docs/design/identity.md` § Approval). It exists because
  suspending is not enough on its own: the row keeps the address, `users.email` is unique, and
  an issuer where anyone may type any address into their own profile can otherwise park a
  colleague's address on this node for ever. Refusing an account has to be able to undo itself.

  **Never approved, rather than "has no rows".** Approval is already the perimeter — a pending
  account reaches no project, answers no question and decides no proposal — so it is by
  construction outside the set that `answers`, `approvals`, `proposal_decisions` and
  `project_members` protect with `on_delete: :restrict`.

  Those references are also the enforcement and not merely the reason. The delete is attempted
  and the database refuses it if anything points at the row; nothing here asks in Elixir whether
  the account has acted and then deletes on the strength of the answer. Those are two models of
  the same question and they can disagree under a race, which is exactly what CLAUDE.md § Rules
  means by a guard using the same model as the operation it guards.

  The event outlives the row: `user.deleted` names the actor and the address freed, so the record
  of the deletion survives even though the account does not.
  """
  @spec delete_unapproved_user(User.t(), User.t()) ::
          {:ok, User.t()} | {:error, :forbidden | :approved | :has_history}
  def delete_unapproved_user(%User{}, %User{node_admin: false}), do: {:error, :forbidden}

  def delete_unapproved_user(%User{approved_at: %DateTime{}}, %User{}), do: {:error, :approved}

  def delete_unapproved_user(%User{approved_at: nil} = user, %User{} = by) do
    Multi.new()
    |> Multi.delete(:user, user)
    |> Events.log(:event, "user.deleted", {:user, by.id}, fn _changes ->
      %{payload: %{"user_id" => user.id, "email" => user.email}}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> {:ok, user}
      {:error, _step, _reason, _changes} -> {:error, :has_history}
    end
  rescue
    # **Rescued rather than enumerated.** A `restrict` reference that nothing has declared as a
    # changeset constraint raises instead of returning, and the tables that hold one are
    # `answers`, `approvals`, `proposal_decisions` and `project_members` today. Naming all four
    # here as `foreign_key_constraint/3` calls would be a second copy of the schema, and the
    # failure mode when somebody adds a fifth is this function raising through a LiveView rather
    # than saying no — so the database is left to be the single authority on whether the row is
    # referenced, and every answer it gives is one answer here.
    _error in Ecto.ConstraintError -> {:error, :has_history}
  end

  defp last_node_admin?(%User{id: id}) do
    not Repo.exists?(from u in User, where: u.node_admin == true and u.id != ^id)
  end

  # The actor is checked here and not only at the router. `/accounts` sits behind
  # `on_mount(:require_node_admin)`, but a page is not a guard — the identical shape was found
  # open in `Forge.Projects.put_member/4`, where the page was the only thing refusing.
  defp govern(%User{}, %User{node_admin: false}, _type, _changes), do: {:error, :forbidden}

  # `:host` is the command line, which is past every gate there is and is the only way the first
  # node admin's account can be approved — nobody exists yet who could approve it.
  defp govern(%User{} = user, :host, type, changes),
    do: apply_governance(user, :system, type, changes)

  defp govern(%User{} = user, %User{} = by, type, changes),
    do: apply_governance(user, {:user, by.id}, type, changes)

  defp apply_governance(%User{} = user, actor, type, changes) do
    Multi.new()
    |> Multi.update(:user, Ecto.Changeset.change(user, changes))
    |> Events.log(:event, type, actor, fn %{user: user} ->
      %{payload: %{"user_id" => user.id, "email" => user.email}}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    # A *pending* account keeps its session on purpose: it has somewhere to be, the page that
    # says it is waiting, and `ForgeWeb.UserAuth.require_approved_user/2` is what sends it
    # there. A *suspended* one has nowhere to be, so its session stops resolving here.
    case Repo.one(query) do
      {%User{suspended_at: %DateTime{}}, _authenticated_at} -> nil
      other -> other
    end
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
