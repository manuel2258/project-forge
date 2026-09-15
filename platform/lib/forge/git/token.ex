defmodule Forge.Git.Token do
  @moduledoc """
  A credential for the platform's git endpoint.

  Not a user token: it has no user, its scope is a ref rather than an account, and its lifetime
  is a job rather than "until revoked". Only the mechanics are shared with
  `Forge.Accounts.UserToken` — 32 random bytes handed out once, a sha256 hash stored.

  `ref` is the one ref a write token may update: `refs/heads/ticket/<n>` for a ticket's job, or
  `refs/heads/chat/<uuid>` for a conversation. A read token has none.
  See `docs/design/git-hosting.md` and `docs/design/conversations.md` § Commits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @write_ref ~r{^refs/heads/(ticket/\d+|chat/#{@uuid})$}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "git_tokens" do
    field :token_hash, :binary, redact: true
    field :ref, :string
    field :write, :boolean, default: false
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [
      :token_hash,
      :project_id,
      :ticket_id,
      :job_id,
      :ref,
      :write,
      :expires_at
    ])
    |> validate_required([:token_hash, :project_id, :expires_at])
    |> validate_ref()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint(:token_hash)
  end

  # A write token without a ref would be a credential for the whole repository, which is the one
  # thing the branch discipline exists to prevent.
  defp validate_ref(changeset) do
    case {get_field(changeset, :write), get_field(changeset, :ref)} do
      {true, nil} ->
        add_error(changeset, :ref, "is required for a write token")

      {_write, nil} ->
        changeset

      {_write, _ref} ->
        # The same two namespaces `priv/git-hooks/pre-receive` accepts, and for the same reason:
        # a token wider than one branch is a token that can write someone else's work. Both are
        # matched to their shape rather than to a glob — the hook is the enforcement point and
        # this is what is allowed to be minted, so they have to agree.
        validate_format(changeset, :ref, @write_ref,
          message: "must be refs/heads/ticket/<number> or refs/heads/chat/<id>"
        )
    end
  end
end
