defmodule Forge.Git.Token do
  @moduledoc """
  A credential for the platform's git endpoint.

  Not a user token: it has no user, its scope is a ref rather than an account, and its lifetime
  is a job rather than "until revoked". Only the mechanics are shared with
  `Forge.Accounts.UserToken` — 32 random bytes handed out once, a sha256 hash stored.

  `ref` is the one ref a write token may update: `refs/heads/ticket/<n>` for a ticket's job,
  `refs/heads/chat/<uuid>` for a conversation, or the project's default branch for the token an
  operator mints by hand. A read token has none.
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

  @doc """
  The changeset every token is minted through.

  `default_branch` is the project's, and this is the only place that knows a ref naming it is
  mintable at all: the shape is per-project, so it cannot live in a module attribute the way the
  ticket and chat namespaces do. It must agree with `forge.defaultBranch` in the repository, which
  `Forge.Git.Hooks.install/2` writes from the same column.
  """
  def create_changeset(token, attrs, default_branch) do
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
    |> validate_ref(default_branch)
    |> validate_not_a_job_on_the_default_branch(default_branch)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:ticket_id)
    |> foreign_key_constraint(:job_id)
    |> unique_constraint(:token_hash)
  end

  # A write token without a ref would be a credential for the whole repository, which is the one
  # thing the branch discipline exists to prevent.
  defp validate_ref(changeset, default_branch) do
    case {get_field(changeset, :write), get_field(changeset, :ref)} do
      {true, nil} ->
        add_error(changeset, :ref, "is required for a write token")

      {_write, nil} ->
        changeset

      {_write, ref} ->
        # The same namespaces `priv/git-hooks/pre-receive` accepts, and for the same reason: a
        # token wider than one branch is a token that can write someone else's work. Ticket and
        # chat are matched to their shape rather than to a glob; the default branch is matched
        # against the project's own rather than a pattern, because `main` is only privileged
        # where it is the default. The hook is the enforcement point and this is what may be
        # minted, so the two have to agree.
        if default?(ref, default_branch) do
          changeset
        else
          validate_format(changeset, :ref, @write_ref,
            message:
              "must be refs/heads/ticket/<number>, refs/heads/chat/<id> or refs/heads/" <>
                (default_branch || "<default branch>")
          )
        end
    end
  end

  # The default-branch token is an operator's, minted by hand from the project's settings page.
  # A job's is issued by the engine for the branch that job works on, and `Tokens.issue_for_job/3`
  # asks for nothing else — this is the guard that says so at the point of minting, so the
  # property "no credential a job holds can move the default branch" does not rest on every
  # caller remembering it. See `docs/design/git-hosting.md` § The default-branch token.
  defp validate_not_a_job_on_the_default_branch(changeset, default_branch) do
    if get_field(changeset, :job_id) && default?(get_field(changeset, :ref), default_branch) do
      add_error(changeset, :ref, "a job is never given the default branch")
    else
      changeset
    end
  end

  defp default?(ref, branch) when is_binary(ref) and is_binary(branch),
    do: ref == "refs/heads/" <> branch

  defp default?(_ref, _branch), do: false
end
